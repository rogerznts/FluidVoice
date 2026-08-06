@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T013: provisional-to-final replacement, preservation of user edits,
/// and the time anchoring insights depend on.
final class LiveTranscriptReconciliationTests: XCTestCase {
    private let trackID = UUID()

    // MARK: - Helpers

    private func time(_ seconds: Double) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64(seconds * 600), timescale: 600)
    }

    private func provisional(
        _ text: String,
        from start: Double,
        to end: Double,
        revision: Int = 0,
        id: MeetingTranscriptSegmentID = UUID()
    ) -> MeetingTranscriptSegment {
        var segment = LiveTranscriptSegmentBuilder.makeSegment(
            text: text,
            trackID: self.trackID,
            start: self.time(start),
            end: self.time(end),
            id: id
        )
        segment.revision = revision
        return segment
    }

    private func finalSegment(
        _ text: String,
        from start: Double,
        to end: Double,
        id: MeetingTranscriptSegmentID = UUID()
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: id,
            start: self.time(start),
            end: self.time(end),
            sourceTrackID: self.trackID,
            speakerID: UUID(),
            text: text,
            revision: 1,
            status: .final,
            overlap: .none,
            completeness: .complete
        )
    }

    // MARK: - Builder

    func testBuilderProducesProvisionalSegment() {
        let segment = LiveTranscriptSegmentBuilder.makeSegment(
            text: "hello there",
            trackID: self.trackID,
            start: self.time(1),
            end: self.time(3)
        )

        XCTAssertEqual(segment.status, .provisional)
        XCTAssertEqual(segment.revision, 0)
        XCTAssertNil(segment.speakerID)
        XCTAssertEqual(segment.sourceTrackID, self.trackID)
        XCTAssertEqual(segment.text, "hello there")
    }

    // MARK: - Replacement

    func testUntouchedProvisionalSegmentsAreReplacedByFinalOutput() {
        let existing = [
            self.provisional("helo ther", from: 0, to: 3),
            self.provisional("secnd bit", from: 3, to: 6),
        ]
        let final = [
            self.finalSegment("Hello there", from: 0, to: 3),
            self.finalSegment("Second bit", from: 3, to: 6),
        ]

        let reconciled = LiveTranscriptReconciler.reconcile(existing: existing, finalSegments: final)

        XCTAssertEqual(reconciled.count, 2)
        XCTAssertEqual(reconciled.map(\.text), ["Hello there", "Second bit"])
        XCTAssertTrue(reconciled.allSatisfy { $0.status == .final })
    }

    /// R-03: the failure mode that would silently destroy the user's work.
    func testUserEditedProvisionalSegmentSurvivesReconciliation() {
        let editedID = UUID()
        let existing = [
            self.provisional("untouched", from: 0, to: 3),
            self.provisional("Corrected by the user", from: 10, to: 12, revision: 2, id: editedID),
        ]
        let final = [self.finalSegment("Hello there", from: 0, to: 3)]

        let reconciled = LiveTranscriptReconciler.reconcile(existing: existing, finalSegments: final)

        let survivor = reconciled.first { $0.id == editedID }
        XCTAssertNotNil(survivor)
        XCTAssertEqual(survivor?.text, "Corrected by the user")
        XCTAssertEqual(survivor?.status, .final, "a preserved edit must be promoted, not left provisional")
        XCTAssertFalse(reconciled.contains { $0.text == "untouched" })
    }

    func testReconciliationSortsByStartTime() {
        let existing = [self.provisional("edited late", from: 30, to: 32, revision: 3)]
        let final = [
            self.finalSegment("third", from: 20, to: 22),
            self.finalSegment("first", from: 0, to: 2),
            self.finalSegment("second", from: 10, to: 12),
        ]

        let reconciled = LiveTranscriptReconciler.reconcile(existing: existing, finalSegments: final)

        XCTAssertEqual(reconciled.map(\.text), ["first", "second", "third", "edited late"])
    }

    func testFinalSegmentWithSameIDWins() {
        let sharedID = UUID()
        let existing = [self.provisional("provisional text", from: 0, to: 3, id: sharedID)]
        let final = [self.finalSegment("authoritative text", from: 0, to: 3, id: sharedID)]

        let reconciled = LiveTranscriptReconciler.reconcile(existing: existing, finalSegments: final)

        XCTAssertEqual(reconciled.count, 1)
        XCTAssertEqual(reconciled.first?.text, "authoritative text")
    }

    func testReconcilingEmptySessionJustTakesFinalOutput() {
        let final = [self.finalSegment("only", from: 0, to: 2)]

        let reconciled = LiveTranscriptReconciler.reconcile(existing: [], finalSegments: final)

        XCTAssertEqual(reconciled, final)
    }

    // MARK: - In-Place Session Reconciliation

    func testSessionReconciliationReportsChange() {
        var session = self.makeSession()
        session.transcriptSegments = [self.provisional("draft", from: 0, to: 2)]

        let changed = LiveTranscriptReconciler.reconcile(
            session: &session,
            finalSegments: [self.finalSegment("done", from: 0, to: 2)]
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(session.transcriptSegments.map(\.text), ["done"])
    }

    func testSessionReconciliationIsIdempotent() {
        var session = self.makeSession()
        let final = [self.finalSegment("done", from: 0, to: 2)]
        session.transcriptSegments = final

        let changed = LiveTranscriptReconciler.reconcile(session: &session, finalSegments: final)

        XCTAssertFalse(changed, "reconciling identical content must not dirty the session")
    }

    // MARK: - Failure Path

    /// `STATE-005` in spirit: on processing failure, provisional text must not
    /// be presented as if it were the result.
    func testDiscardUntouchedProvisionalKeepsOnlyFinalAndEdits() {
        let segments = [
            self.provisional("untouched", from: 0, to: 2),
            self.provisional("edited", from: 2, to: 4, revision: 5),
            self.finalSegment("final", from: 4, to: 6),
        ]

        let kept = LiveTranscriptReconciler.discardUntouchedProvisional(in: segments)

        XCTAssertEqual(Set(kept.map(\.text)), ["edited", "final"])
    }

    // MARK: - Fixtures

    private func makeSession() -> MeetingSession {
        MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom,
                title: "Test",
                languageCode: "en",
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "dev", displayName: "Mic")
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            transcriptMode: .live
        )
    }
}
