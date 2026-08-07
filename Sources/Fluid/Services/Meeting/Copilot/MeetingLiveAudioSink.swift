import AVFoundation
import CoreMedia
import Foundation

// MARK: - Sink Protocol

/// Receives a copy of captured audio for live, best-effort processing.
///
/// The contract that makes this safe (AD-001, `CAP-012`, `LIVE-003`):
/// `receive` runs on the capture callback thread, so it **must return
/// immediately** and **must never block**. An implementation that cannot keep up
/// drops audio. It never applies backpressure, because the only thing upstream
/// of it is the durable write to disk, and losing meeting audio to feed a live
/// convenience would invert the product's priorities.
nonisolated protocol MeetingLiveAudioSink: AnyObject, Sendable {
    func receive(_ sampleBuffer: CMSampleBuffer, from kind: MeetingAudioTrackKind)
}

// MARK: - Bounded Buffer

/// A fixed-capacity ring of audio chunks, written from the capture callback and
/// drained by the live consumer.
///
/// Bounded on purpose: an unbounded queue would trade a visible drop for an
/// invisible memory leak across a long meeting (`CAP-011`).
final class MeetingLiveAudioBuffer: @unchecked Sendable {
    struct Chunk: Sendable {
        let samples: [Float]
        let sampleRate: Double
        let kind: MeetingAudioTrackKind
        let presentationTime: MeetingMediaTime
    }

    private let capacity: Int
    private let lock = NSLock()
    private var chunks: [Chunk] = []
    private var droppedCount: Int = 0

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    /// Number of chunks discarded because the consumer fell behind. Surfaced so
    /// degraded live transcription can be explained rather than guessed at.
    var dropped: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.droppedCount
    }

    var isEmpty: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.chunks.isEmpty
    }

    /// Appends a chunk, discarding the **oldest** when full.
    ///
    /// Dropping the oldest rather than the newest keeps the live transcript
    /// tracking the present, which is the only part of the conversation the
    /// copilot can still act on.
    @discardableResult
    func append(_ chunk: Chunk) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }

        if self.chunks.count >= self.capacity {
            self.chunks.removeFirst()
            self.droppedCount += 1
            self.chunks.append(chunk)
            return false
        }
        self.chunks.append(chunk)
        return true
    }

    func drain() -> [Chunk] {
        self.lock.lock()
        defer { self.lock.unlock() }
        let drained = self.chunks
        self.chunks.removeAll(keepingCapacity: true)
        return drained
    }

    func reset() {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.chunks.removeAll(keepingCapacity: true)
        self.droppedCount = 0
    }
}

// MARK: - Sample Buffer Conversion

nonisolated enum MeetingLiveAudioConverter {
    /// Extracts mono `Float` samples from a capture sample buffer.
    ///
    /// Returns `nil` rather than throwing: this runs on the capture callback,
    /// where the only correct response to an odd buffer is to skip it and let
    /// the durable path carry on.
    static func monoSamples(from sampleBuffer: CMSampleBuffer) -> (samples: [Float], sampleRate: Double)? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return nil }

        let format = streamDescription.pointee
        let sampleRate = format.mSampleRate
        guard sampleRate > 0 else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }

        let channelCount = Int(format.mChannelsPerFrame)
        guard channelCount > 0 else { return nil }

        let isFloat = (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isInterleaved = (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
        guard isFloat, format.mBitsPerChannel == 32 else { return nil }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return nil }

        let floatCount = totalLength / MemoryLayout<Float>.size
        guard floatCount > 0 else { return nil }

        let mixed: [Float] = dataPointer.withMemoryRebound(to: Float.self, capacity: floatCount) { pointer in
            let buffer = UnsafeBufferPointer(start: pointer, count: floatCount)
            guard channelCount > 1 else {
                return Array(buffer)
            }

            // Downmix to mono: ASR takes one channel, and mixing preserves a
            // speaker that happens to sit on one side.
            let frames = min(frameCount, floatCount / channelCount)
            var result = [Float](repeating: 0, count: frames)
            let scale = 1.0 / Float(channelCount)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    let index = isInterleaved
                        ? frame * channelCount + channel
                        : channel * frames + frame
                    guard index < floatCount else { continue }
                    sum += buffer[index]
                }
                result[frame] = sum * scale
            }
            return result
        }

        return (mixed, sampleRate)
    }

    static func presentationTime(of sampleBuffer: CMSampleBuffer) -> MeetingMediaTime {
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard time.isValid, time.timescale > 0 else {
            return MeetingMediaTime(value: 0, timescale: 1)
        }
        return MeetingMediaTime(value: time.value, timescale: time.timescale)
    }
}
