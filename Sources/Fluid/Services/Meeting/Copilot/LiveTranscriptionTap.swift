import AVFoundation
import CoreMedia
import Foundation

// MARK: - Configuration

nonisolated struct LiveTranscriptionTapConfiguration: Sendable {
    /// ASR input rate. 16 kHz mono is what every bundled provider expects.
    static let targetSampleRate: Double = 16000

    /// How much speech accumulates before a transcription pass runs. Short
    /// enough to stay responsive, long enough that the model has real context.
    var windowDuration: TimeInterval = 6.0

    /// Minimum gap between passes, so a talkative meeting cannot spin the model
    /// continuously (`FR-011`).
    var minimumInterval: TimeInterval = 2.0

    /// Below this RMS a window counts as silence and never reaches the model
    /// (`FR-009`: no speech, no call).
    var silenceThreshold: Float = 0.005

    /// Ring capacity in captured chunks. Roughly a few seconds of audio; beyond
    /// it the consumer is too far behind for the extra audio to be useful.
    var bufferCapacity: Int = 64
}

// MARK: - Delegate

/// Receives provisional transcription output.
///
/// Deliberately not the session store: the tap produces text, and the
/// coordinator decides how it lands on the session.
nonisolated protocol LiveTranscriptionTapDelegate: AnyObject, Sendable {
    func liveTranscription(
        didProduce text: String,
        from kind: MeetingAudioTrackKind,
        start: MeetingMediaTime,
        end: MeetingMediaTime
    ) async

    /// Reports that audio was dropped because the consumer fell behind, so the
    /// UI can mark the live transcript degraded instead of silently lying.
    func liveTranscriptionDidDropAudio(count: Int) async
}

// MARK: - Tap

/// Turns captured audio into provisional transcript text for the copilot.
///
/// Everything here is best-effort by construction (AD-001):
/// - `receive` only appends to a bounded ring and returns; it never blocks the
///   capture callback (`CAP-012`).
/// - When the ring overflows, audio is dropped rather than backpressured, so a
///   slow model can never stall the durable write path (R-02).
/// - When the offline pipeline wants the ASR provider, the tap yields and skips
///   its window (`PIPE-015`).
final class LiveTranscriptionTap: MeetingLiveAudioSink, @unchecked Sendable {
    private let configuration: LiveTranscriptionTapConfiguration
    private let providerFactory: @Sendable () async throws -> any TranscriptionProvider
    private let arbiter: MeetingASRAccessArbiter
    private weak var delegate: (any LiveTranscriptionTapDelegate)?

    private let buffer: MeetingLiveAudioBuffer
    private let stateLock = NSLock()
    private var pendingSamples: [MeetingAudioTrackKind: [Float]] = [:]
    private var windowStart: [MeetingAudioTrackKind: MeetingMediaTime] = [:]
    private var windowEnd: [MeetingAudioTrackKind: MeetingMediaTime] = [:]
    private var reportedDrops = 0

    private var pumpTask: Task<Void, Never>?

    init(
        configuration: LiveTranscriptionTapConfiguration = LiveTranscriptionTapConfiguration(),
        arbiter: MeetingASRAccessArbiter = .shared,
        delegate: (any LiveTranscriptionTapDelegate)? = nil,
        providerFactory: @escaping @Sendable () async throws -> any TranscriptionProvider
    ) {
        self.configuration = configuration
        self.arbiter = arbiter
        self.delegate = delegate
        self.providerFactory = providerFactory
        self.buffer = MeetingLiveAudioBuffer(capacity: configuration.bufferCapacity)
    }

    deinit {
        self.pumpTask?.cancel()
    }

    func setDelegate(_ delegate: (any LiveTranscriptionTapDelegate)?) {
        self.stateLock.lock()
        self.delegate = delegate
        self.stateLock.unlock()
    }

    // MARK: - MeetingLiveAudioSink

    /// Runs on the capture callback thread. Does the minimum: convert and
    /// append. No I/O, no `await`, no allocation beyond the sample copy.
    func receive(_ sampleBuffer: CMSampleBuffer, from kind: MeetingAudioTrackKind) {
        guard let converted = MeetingLiveAudioConverter.monoSamples(from: sampleBuffer) else { return }
        let presentationTime = MeetingLiveAudioConverter.presentationTime(of: sampleBuffer)

        self.buffer.append(
            MeetingLiveAudioBuffer.Chunk(
                samples: converted.samples,
                sampleRate: converted.sampleRate,
                kind: kind,
                presentationTime: presentationTime
            )
        )
    }

    // MARK: - Lifecycle

    func start() {
        self.stop()
        self.buffer.reset()

        self.stateLock.lock()
        self.pendingSamples.removeAll()
        self.windowStart.removeAll()
        self.windowEnd.removeAll()
        self.reportedDrops = 0
        self.stateLock.unlock()

        self.pumpTask = Task { [weak self] in
            await self?.pump()
        }
    }

    func stop() {
        self.pumpTask?.cancel()
        self.pumpTask = nil
    }

    /// Drops everything buffered without transcribing it. Used on Stop, where a
    /// half-finished live pass has no value — the offline pipeline is about to
    /// produce the authoritative text anyway.
    func discardPending() {
        self.buffer.reset()
        self.stateLock.lock()
        self.pendingSamples.removeAll()
        self.windowStart.removeAll()
        self.windowEnd.removeAll()
        self.stateLock.unlock()
    }

    // MARK: - Pump

    private func pump() async {
        let intervalNanoseconds = UInt64(self.configuration.minimumInterval * 1_000_000_000)

        while !Task.isCancelled {
            self.drainBuffer()
            await self.reportDropsIfNeeded()

            for kind in self.readyWindows() {
                guard !Task.isCancelled else { return }
                await self.transcribeWindow(for: kind)
            }

            try? await Task.sleep(nanoseconds: intervalNanoseconds)
        }
    }

    /// Moves audio out of the ring and into per-track windows, resampling to the
    /// ASR rate off the capture thread (`CAP-014`).
    private func drainBuffer() {
        let chunks = self.buffer.drain()
        guard !chunks.isEmpty else { return }

        for chunk in chunks {
            let resampled = Self.resample(
                chunk.samples,
                from: chunk.sampleRate,
                to: LiveTranscriptionTapConfiguration.targetSampleRate
            )
            guard !resampled.isEmpty else { continue }

            let duration = Double(chunk.samples.count) / chunk.sampleRate
            let end = MeetingMediaTime(
                value: chunk.presentationTime.value
                    + Int64(duration * Double(chunk.presentationTime.timescale)),
                timescale: chunk.presentationTime.timescale
            )

            self.stateLock.lock()
            self.pendingSamples[chunk.kind, default: []].append(contentsOf: resampled)
            if self.windowStart[chunk.kind] == nil {
                self.windowStart[chunk.kind] = chunk.presentationTime
            }
            self.windowEnd[chunk.kind] = end
            self.stateLock.unlock()
        }
    }

    private func readyWindows() -> [MeetingAudioTrackKind] {
        let required = Int(self.configuration.windowDuration * LiveTranscriptionTapConfiguration.targetSampleRate)

        self.stateLock.lock()
        defer { self.stateLock.unlock() }

        return self.pendingSamples
            .filter { $0.value.count >= required }
            .map(\.key)
            .sorted { $0.rawValue < $1.rawValue }
    }

    private func transcribeWindow(for kind: MeetingAudioTrackKind) async {
        self.stateLock.lock()
        let samples = self.pendingSamples[kind] ?? []
        let start = self.windowStart[kind]
        let end = self.windowEnd[kind]
        self.pendingSamples[kind] = []
        self.windowStart[kind] = nil
        self.stateLock.unlock()

        guard !samples.isEmpty, let start, let end else { return }

        // `FR-009`: silence never reaches the provider.
        guard Self.rootMeanSquare(samples) >= self.configuration.silenceThreshold else { return }

        let outcome: String? = await self.arbiter.runLiveIfAvailable { [providerFactory] in
            do {
                let provider = try await providerFactory()
                guard provider.isReady else { return nil }
                let result = try await provider.transcribeStreaming(samples)
                let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } catch {
                // Live transcription failing is not a session failure (`FR-002`).
                DebugLogger.shared.log(
                    "LiveTranscriptionTap: streaming pass failed — \(error.localizedDescription)",
                    level: .warning,
                    source: "MeetingCopilot"
                )
                return nil
            }
        } ?? nil

        guard let text = outcome else { return }
        await self.delegate?.liveTranscription(didProduce: text, from: kind, start: start, end: end)
    }

    private func reportDropsIfNeeded() async {
        let dropped = self.buffer.dropped

        self.stateLock.lock()
        let previouslyReported = self.reportedDrops
        let isNew = dropped > previouslyReported
        if isNew {
            self.reportedDrops = dropped
        }
        self.stateLock.unlock()

        guard isNew else { return }
        await self.delegate?.liveTranscriptionDidDropAudio(count: dropped)
    }

    // MARK: - Audio Helpers

    static func rootMeanSquare(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float.zero) { $0 + $1 * $1 }
        return (sumOfSquares / Float(samples.count)).squareRoot()
    }

    /// Resamples mono float audio, reusing the app's existing converter so the
    /// live path and dictation agree on how audio is prepared.
    /// Returns an empty array when the audio cannot be converted. Empty and
    /// failure collapse to the same caller action — skip this chunk — so an
    /// optional would add a case with no distinct handling.
    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return [] }
        guard sourceRate != targetRate else { return samples }

        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return [] }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else { return [] }
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channelData[0].update(from: base, count: samples.count)
        }

        return (try? AudioBufferConverter.monoSamples(from: buffer, targetSampleRate: targetRate)) ?? []
    }
}
