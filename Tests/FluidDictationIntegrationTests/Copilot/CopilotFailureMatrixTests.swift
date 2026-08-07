@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T053 and `SC-005`: every way the copilot can fail must leave capture,
/// transcription, and the session untouched.
///
/// The premise of the whole feature is that AI is a convenience layered over a
/// recorder. If a provider outage can cost audio, that premise is false.
final class CopilotFailureMatrixTests: XCTestCase {
    // MARK: - Unusable Providers

    /// An unconfigured provider must be refused before any request is built,
    /// not discovered mid-meeting.
    func testRouteWithoutModelIsUnusable() {
        let route = CopilotProviderRoute(
            baseURL: "https://api.example.com",
            model: "",
            apiKey: "key",
            choice: .cloud
        )

        XCTAssertFalse(route.isUsable)
    }

    func testRouteWithoutBaseURLIsUnusable() {
        let route = CopilotProviderRoute(baseURL: "", model: "gpt-4o", apiKey: "key", choice: .cloud)

        XCTAssertFalse(route.isUsable)
    }

    /// A local route with no on-device model resolves empty on the public
    /// build. It must read as unusable rather than as a working local setup.
    func testEmptyLocalRouteIsUnusable() {
        let route = CopilotProviderRoute(baseURL: "", model: "", apiKey: "", choice: .local)

        XCTAssertFalse(route.isUsable)
    }

    func testEngineRefusesUnusableRouteWithoutCallingOut() async {
        let engine = CopilotInsightEngine(
            route: CopilotProviderRoute(baseURL: "", model: "", apiKey: "", choice: .cloud),
            language: .english
        )
        let profile = MeetingCopilotProfile(
            name: "Test",
            insightPrompt: "p",
            briefingPrompt: "b",
            insightFormat: .supportingPoints
        )

        do {
            _ = try await engine.run(.automaticInsight, profile: profile, context: CopilotContextWindow())
            XCTFail("an unusable route must throw before any network call")
        } catch {
            XCTAssertEqual(error as? CopilotInsightError, .providerUnavailable)
        }
    }

    // MARK: - Capture Independence

    /// R-02: the live path drops audio rather than pushing back on the writer.
    /// A stalled consumer must cost transcription quality, never recording.
    func testSlowConsumerDropsAudioInsteadOfGrowing() {
        let buffer = MeetingLiveAudioBuffer(capacity: 8)
        let chunk = MeetingLiveAudioBuffer.Chunk(
            samples: [0.1],
            sampleRate: 48000,
            kind: .microphone,
            presentationTime: MeetingMediaTime(value: 0, timescale: 600)
        )

        for _ in 0 ..< 5000 {
            buffer.append(chunk)
        }

        XCTAssertEqual(buffer.drain().count, 8)
        XCTAssertEqual(buffer.dropped, 4992)
    }

    /// `PIPE-015`: the offline pipeline owns the provider; live work yields.
    func testLiveWorkYieldsToOfflineProcessing() async {
        let arbiter = MeetingASRAccessArbiter()
        let started = expectation(description: "offline started")

        let offline = Task {
            await arbiter.runOffline {
                started.fulfill()
                try? await Task.sleep(nanoseconds: 150_000_000)
                return true
            }
        }
        await fulfillment(of: [started], timeout: 2)

        let live = await arbiter.runLiveIfAvailable { true }

        XCTAssertNil(live, "live transcription must be refused while offline processing holds the provider")
        _ = await offline.value
    }

    // MARK: - Transcript Integrity

    /// `STATE-005` in spirit: a failed copilot must not corrupt the transcript.
    /// Reconciliation with no final segments preserves user edits and drops
    /// only untouched provisional text.
    func testProcessingFailureKeepsUserEditsAndDropsProvisional() {
        let trackID = UUID()
        let time = { (s: Double) in MeetingMediaTime(value: Int64(s * 600), timescale: 600) }

        var edited = LiveTranscriptSegmentBuilder.makeSegment(
            text: "corrected by hand",
            trackID: trackID,
            start: time(0),
            end: time(2)
        )
        edited.revision = 3

        let untouched = LiveTranscriptSegmentBuilder.makeSegment(
            text: "raw live text",
            trackID: trackID,
            start: time(2),
            end: time(4)
        )

        let kept = LiveTranscriptReconciler.discardUntouchedProvisional(in: [edited, untouched])

        XCTAssertEqual(kept.map(\.text), ["corrected by hand"])
    }

    /// A cancelled request is a normal outcome, not an error state to surface.
    func testCancellationIsADistinctOutcome() {
        XCTAssertNotEqual(CopilotInsightError.cancelled, CopilotInsightError.providerUnavailable)
        XCTAssertNotEqual(CopilotInsightError.cancelled, CopilotInsightError.emptyResponse)
    }

    // MARK: - Artifact Durability

    /// `FR-020`: audio deletion is not artifact deletion.
    func testArtifactsAreIndependentOfAudio() {
        let artifacts = CopilotSessionArtifacts(
            sessionID: UUID(),
            insights: [
                CopilotInsight(
                    anchor: MeetingMediaTime(value: 0, timescale: 600),
                    origin: .automatic,
                    format: .supportingPoints,
                    profileID: "p"
                ),
            ]
        )

        XCTAssertFalse(artifacts.isEmpty)
        XCTAssertNoThrow(try artifacts.validateForPersistence())
    }

    /// Writing artifacts for a session that was never created would leave an
    /// orphan directory the index knows nothing about.
    func testArtifactsRequireAnExistingSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotFailureMatrix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = MeetingSessionStore(rootDirectory: root)

        do {
            try await store.saveArtifacts(CopilotSessionArtifacts(sessionID: UUID()))
            XCTFail("expected the store to refuse an unknown session")
        } catch {
            XCTAssertEqual(error as? MeetingCopilotArtifactStoreError, .sessionDirectoryMissing)
        }
    }

    // MARK: - Degraded Input

    /// Silence must never reach the provider (`FR-009`): no speech, no call, no
    /// cost.
    func testSilenceNeverReachesTheProvider() {
        let silence = [Float](repeating: 0, count: 16000)
        let threshold = LiveTranscriptionTapConfiguration().silenceThreshold

        XCTAssertLessThan(LiveTranscriptionTap.rootMeanSquare(silence), threshold)
    }

    /// An unreadable audio buffer yields no samples rather than garbage the
    /// model would try to transcribe.
    func testUnconvertibleAudioYieldsNothing() {
        XCTAssertTrue(LiveTranscriptionTap.resample([], from: 48000, to: 16000).isEmpty)
        XCTAssertTrue(LiveTranscriptionTap.resample([0.5], from: 0, to: 16000).isEmpty)
    }
}
