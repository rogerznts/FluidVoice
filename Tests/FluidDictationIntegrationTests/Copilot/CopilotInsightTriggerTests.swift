@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T022: when an automatic insight fires, and the sliding window that
/// keeps prompt cost flat over a long meeting.
final class CopilotInsightTriggerTests: XCTestCase {
    private let trigger = CopilotInsightTrigger()

    private func time(_ seconds: Double) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64(seconds * 600), timescale: 600)
    }

    // MARK: - Trigger Policy

    func testFiresOnSubstantialRemoteSpeech() {
        let fired = self.trigger.shouldFire(
            text: "Can you walk me through how you would design this system?",
            isLocalUser: false,
            lastFiredAt: nil,
            now: self.time(10)
        )

        XCTAssertTrue(fired)
    }

    /// The copilot answers the other side. Reacting to the user's own speech
    /// would suggest replies to themselves.
    func testNeverFiresOnLocalUserSpeech() {
        let fired = self.trigger.shouldFire(
            text: "Can you walk me through how you would design this system?",
            isLocalUser: true,
            lastFiredAt: nil,
            now: self.time(10)
        )

        XCTAssertFalse(fired)
    }

    /// `FR-009`: acknowledgements are not questions to answer.
    func testDoesNotFireOnShortAcknowledgements() {
        for filler in ["ok", "sure", "right", "uh huh", "certo"] {
            XCTAssertFalse(
                self.trigger.shouldFire(text: filler, isLocalUser: false, lastFiredAt: nil, now: self.time(10)),
                "should not fire on \(filler)"
            )
        }
    }

    func testDoesNotFireOnEmptyOrWhitespace() {
        XCTAssertFalse(self.trigger.shouldFire(text: "", isLocalUser: false, lastFiredAt: nil, now: self.time(5)))
        XCTAssertFalse(
            self.trigger.shouldFire(text: "      \n  ", isLocalUser: false, lastFiredAt: nil, now: self.time(5))
        )
    }

    /// `FR-011`: a fast conversation must not spin the provider continuously.
    func testThrottlesRapidConsecutiveTurns() {
        let long = "This is a long enough question to clear the character floor."

        let tooSoon = self.trigger.shouldFire(
            text: long,
            isLocalUser: false,
            lastFiredAt: self.time(10),
            now: self.time(12)
        )
        let farEnough = self.trigger.shouldFire(
            text: long,
            isLocalUser: false,
            lastFiredAt: self.time(10),
            now: self.time(25)
        )

        XCTAssertFalse(tooSoon, "2s after the last insight is inside the throttle")
        XCTAssertTrue(farEnough, "15s later is outside it")
    }

    func testFiresExactlyAtTheThrottleBoundary() {
        let fired = self.trigger.shouldFire(
            text: "A question long enough to pass the character threshold here.",
            isLocalUser: false,
            lastFiredAt: self.time(10),
            now: self.time(18)
        )

        XCTAssertTrue(fired, "the interval is inclusive at its boundary")
    }

    // MARK: - Context Window

    func testWindowKeepsEntriesInOrder() {
        var window = CopilotContextWindow()
        window.append(speaker: "Them", text: "first", time: self.time(1), isLocalUser: false)
        window.append(speaker: "You", text: "second", time: self.time(2), isLocalUser: true)

        XCTAssertEqual(window.entries.map(\.text), ["first", "second"])
        XCTAssertEqual(window.latestEntry?.text, "second")
        XCTAssertEqual(window.latestEntry?.isLocalUser, true)
    }

    func testWindowIgnoresEmptyText() {
        var window = CopilotContextWindow()
        window.append(speaker: "Them", text: "   ", time: self.time(1), isLocalUser: false)

        XCTAssertTrue(window.isEmpty)
    }

    /// R-04: cost and latency stay flat no matter how long the meeting runs.
    func testWindowEvictsOldestBeyondBudget() {
        var window = CopilotContextWindow(characterBudget: 500)
        let line = String(repeating: "x", count: 100)

        for index in 0 ..< 20 {
            window.append(speaker: "Them", text: "\(index)-\(line)", time: self.time(Double(index)), isLocalUser: false)
        }

        let total = window.entries.reduce(0) { $0 + $1.text.count }
        XCTAssertLessThanOrEqual(total, 600, "window must stay near its budget")
        XCTAssertTrue(window.entries.last?.text.hasPrefix("19-") == true, "newest entry is retained")
        XCTAssertFalse(window.entries.contains { $0.text.hasPrefix("0-") }, "oldest entry was evicted")
    }

    func testEvictedEntriesAreTrackedForSummarisation() {
        var window = CopilotContextWindow(characterBudget: 500)
        for index in 0 ..< 20 {
            window.append(
                speaker: "Them",
                text: String(repeating: "y", count: 100),
                time: self.time(Double(index)),
                isLocalUser: false
            )
        }

        XCTAssertFalse(window.evictedSinceLastSummary.isEmpty)

        window.setRollingSummary("They discussed the migration plan.")

        XCTAssertTrue(window.evictedSinceLastSummary.isEmpty, "setting a summary clears the backlog")
        XCTAssertEqual(window.rollingSummary, "They discussed the migration plan.")
    }

    func testPromptContextIncludesSummaryAndTranscript() {
        var window = CopilotContextWindow()
        window.append(speaker: "Them", text: "What about latency?", time: self.time(1), isLocalUser: false)
        window.setRollingSummary("Earlier they covered throughput.")

        let context = window.promptContext()

        XCTAssertTrue(context.contains("Earlier they covered throughput."))
        XCTAssertTrue(context.contains("Them: What about latency?"))
    }

    func testPromptContextOmitsSummarySectionWhenAbsent() {
        var window = CopilotContextWindow()
        window.append(speaker: "Them", text: "Only line", time: self.time(1), isLocalUser: false)

        XCTAssertFalse(window.promptContext().contains("Earlier in the meeting"))
    }

    func testResetClearsEverything() {
        var window = CopilotContextWindow()
        window.append(speaker: "Them", text: "something", time: self.time(1), isLocalUser: false)
        window.setRollingSummary("summary")

        window.reset()

        XCTAssertTrue(window.isEmpty)
        XCTAssertEqual(window.rollingSummary, "")
    }

    /// The window must never drop to nothing: the current turn is what an
    /// insight is answering.
    func testWindowAlwaysRetainsAtLeastOneEntry() {
        var window = CopilotContextWindow(characterBudget: 500)
        window.append(
            speaker: "Them",
            text: String(repeating: "z", count: 5000),
            time: self.time(1),
            isLocalUser: false
        )

        XCTAssertEqual(window.entries.count, 1)
    }
}
