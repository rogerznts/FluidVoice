@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T014 and the arbitration in T011.
///
/// The property under test is the one that protects the recording: when the
/// live consumer cannot keep up, audio is **dropped**, never queued without
/// bound and never pushed back onto the capture callback (AD-001, R-02,
/// `CAP-011`).
final class LiveAudioBackpressureTests: XCTestCase {
    // MARK: - Bounded Buffer

    private func makeChunk(_ marker: Float) -> MeetingLiveAudioBuffer.Chunk {
        MeetingLiveAudioBuffer.Chunk(
            samples: [marker],
            sampleRate: 48000,
            kind: .microphone,
            presentationTime: MeetingMediaTime(value: Int64(marker), timescale: 600)
        )
    }

    func testBufferAcceptsUpToCapacity() {
        let buffer = MeetingLiveAudioBuffer(capacity: 4)

        for index in 0 ..< 4 {
            XCTAssertTrue(buffer.append(self.makeChunk(Float(index))))
        }

        XCTAssertEqual(buffer.dropped, 0)
        XCTAssertEqual(buffer.drain().count, 4)
    }

    /// The core guarantee: a slow consumer costs audio, not memory.
    func testBufferDropsInsteadOfGrowingWithoutBound() {
        let buffer = MeetingLiveAudioBuffer(capacity: 8)

        for index in 0 ..< 10000 {
            buffer.append(self.makeChunk(Float(index)))
        }

        let drained = buffer.drain()
        XCTAssertEqual(drained.count, 8, "buffer must never exceed its capacity")
        XCTAssertEqual(buffer.dropped, 9992)
    }

    /// Dropping the oldest keeps the live transcript tracking the present,
    /// which is the only part the copilot can still act on.
    func testBufferDropsOldestChunksFirst() {
        let buffer = MeetingLiveAudioBuffer(capacity: 3)

        for index in 0 ..< 6 {
            buffer.append(self.makeChunk(Float(index)))
        }

        let markers = buffer.drain().compactMap(\.samples.first)
        XCTAssertEqual(markers, [3, 4, 5])
    }

    func testDrainLeavesBufferEmpty() {
        let buffer = MeetingLiveAudioBuffer(capacity: 4)
        buffer.append(self.makeChunk(1))

        _ = buffer.drain()

        XCTAssertTrue(buffer.isEmpty)
    }

    func testResetClearsDropCounter() {
        let buffer = MeetingLiveAudioBuffer(capacity: 1)
        buffer.append(self.makeChunk(1))
        buffer.append(self.makeChunk(2))
        XCTAssertEqual(buffer.dropped, 1)

        buffer.reset()

        XCTAssertEqual(buffer.dropped, 0)
        XCTAssertTrue(buffer.isEmpty)
    }

    /// Stands in for the capture callback: many threads appending at once must
    /// not corrupt state or exceed capacity.
    func testConcurrentAppendsStayWithinCapacity() {
        let buffer = MeetingLiveAudioBuffer(capacity: 16)

        DispatchQueue.concurrentPerform(iterations: 500) { index in
            buffer.append(self.makeChunk(Float(index)))
        }

        XCTAssertLessThanOrEqual(buffer.drain().count, 16)
    }

    // MARK: - Silence Gate

    /// `FR-009`: no speech, no provider call.
    func testSilentWindowFallsBelowThreshold() {
        let silence = [Float](repeating: 0, count: 16000)

        XCTAssertLessThan(LiveTranscriptionTap.rootMeanSquare(silence), 0.005)
    }

    func testSpeechLikeWindowClearsThreshold() {
        let speech = (0 ..< 16000).map { index in
            sin(Float(index) * 0.05) * 0.3
        }

        XCTAssertGreaterThan(LiveTranscriptionTap.rootMeanSquare(speech), 0.005)
    }

    func testRootMeanSquareOfEmptyWindowIsZero() {
        XCTAssertEqual(LiveTranscriptionTap.rootMeanSquare([]), 0)
    }

    // MARK: - Resampling

    func testResampleReducesSampleCountForLowerRate() {
        let input = (0 ..< 48000).map { sin(Float($0) * 0.01) }

        let resampled = LiveTranscriptionTap.resample(input, from: 48000, to: 16000)

        XCTAssertGreaterThan(resampled.count, 15000)
        XCTAssertLessThan(resampled.count, 17000)
    }

    func testResampleIsAPassthroughAtMatchingRate() {
        let input: [Float] = [0.1, 0.2, 0.3]

        XCTAssertEqual(LiveTranscriptionTap.resample(input, from: 16000, to: 16000), input)
    }

    func testResampleReturnsEmptyForInvalidInput() {
        XCTAssertTrue(LiveTranscriptionTap.resample([], from: 48000, to: 16000).isEmpty)
        XCTAssertTrue(LiveTranscriptionTap.resample([0.1], from: 0, to: 16000).isEmpty)
        XCTAssertTrue(LiveTranscriptionTap.resample([0.1], from: 48000, to: 0).isEmpty)
    }

    // MARK: - ASR Arbitration (T011)

    /// `PIPE-015`: the authoritative path always wins the provider.
    func testLiveWorkIsRefusedWhileOfflineHoldsProvider() async {
        let arbiter = MeetingASRAccessArbiter()
        let offlineStarted = expectation(description: "offline started")
        let liveAttempted = expectation(description: "live attempted")

        let offlineTask = Task {
            await arbiter.runOffline {
                offlineStarted.fulfill()
                try? await Task.sleep(nanoseconds: 200_000_000)
                return true
            }
        }

        await fulfillment(of: [offlineStarted], timeout: 2)

        let liveResult = await arbiter.runLiveIfAvailable { () -> Bool in
            liveAttempted.fulfill()
            return true
        }

        XCTAssertNil(liveResult, "live work must yield while the offline pass holds the provider")
        _ = await offlineTask.value
    }

    func testLiveWorkRunsWhenProviderIsFree() async {
        let arbiter = MeetingASRAccessArbiter()

        let result = await arbiter.runLiveIfAvailable { "transcribed" }

        XCTAssertEqual(result, "transcribed")
    }

    func testOfflineWorkAlwaysRuns() async {
        let arbiter = MeetingASRAccessArbiter()

        let first = await arbiter.runOffline { 1 }
        let second = await arbiter.runOffline { 2 }

        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
    }

    func testArbiterReportsOfflineActivity() async {
        let arbiter = MeetingASRAccessArbiter()
        let isIdle = await arbiter.isOfflineActive

        XCTAssertFalse(isIdle)
    }
}
