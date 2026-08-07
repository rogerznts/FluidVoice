@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Regression tests for the timing bugs found in phase 4.
///
/// Both were pure arithmetic, invisible to the build, the linter, and every
/// other test in this suite — and both cost a real recording session to find.
/// They are asserted here directly.
final class CopilotTurnAccumulatorTests: XCTestCase {
    private let accumulator = CopilotTurnAccumulator()

    // MARK: - The Two Regressions

    /// **Bug: the debounce never debounced.**
    ///
    /// `LiveTranscriptionTap` emits transcription roughly every
    /// `windowDuration` seconds. A pause threshold shorter than that spacing
    /// means every slice arrives after the debounce has already elapsed, so
    /// each fragment fires its own card — the exact behaviour the debounce was
    /// added to prevent.
    func testTurnPauseExceedsTheLiveTranscriptionInterval() {
        let transcriptionInterval = LiveTranscriptionTapConfiguration().windowDuration

        XCTAssertGreaterThan(
            self.accumulator.turnPause,
            transcriptionInterval,
            """
            turnPause (\(self.accumulator.turnPause)s) must exceed the transcription \
            interval (\(transcriptionInterval)s), or nothing is ever debounced.
            """
        )
    }

    /// **Bug: the ceiling was unreachable before the first insight.**
    ///
    /// It measured against "time since last insight", which does not exist yet
    /// at that point. Treated as zero, continuous speech cancelled the debounce
    /// forever and no suggestion was ever produced. `elapsed` must therefore be
    /// measured from when accumulation began when there is no previous insight.
    func testCeilingFiresEvenWithNoPreviousInsight() {
        let decision = self.accumulator.decide(
            accumulatedCharacters: 50,
            elapsed: self.accumulator.maximumWait + 1
        )

        XCTAssertEqual(
            decision,
            .fireNow,
            "the ceiling must fire on elapsed time alone, even below the character minimum"
        )
    }

    func testCeilingIsReachableWithinAReasonableTime() {
        XCTAssertLessThanOrEqual(
            self.accumulator.maximumWait,
            30,
            "a speaker who never pauses should not wait longer than this for a first suggestion"
        )
    }

    // MARK: - Decision Table

    func testHoldsWhileThereIsNothingToSay() {
        XCTAssertEqual(self.accumulator.decide(accumulatedCharacters: 0, elapsed: 0), .hold)
        XCTAssertEqual(
            self.accumulator.decide(accumulatedCharacters: 0, elapsed: 999),
            .hold,
            "silence never produces a suggestion, however long it lasts"
        )
    }

    func testHoldsBelowTheCharacterMinimum() {
        XCTAssertEqual(
            self.accumulator.decide(accumulatedCharacters: self.accumulator.minimumCharacters - 1, elapsed: 1),
            .hold
        )
    }

    func testWaitsForPauseOnceThereIsEnoughMaterial() {
        XCTAssertEqual(
            self.accumulator.decide(accumulatedCharacters: self.accumulator.minimumCharacters, elapsed: 1),
            .waitForPause
        )
    }

    func testCeilingOverridesTheCharacterMinimum() {
        let decision = self.accumulator.decide(
            accumulatedCharacters: 1,
            elapsed: self.accumulator.maximumWait
        )

        XCTAssertEqual(decision, .fireNow, "the ceiling is inclusive at its boundary")
    }

    // MARK: - Configuration Sanity

    func testMinimumCharactersIsMoreThanOneClause() {
        XCTAssertGreaterThan(
            self.accumulator.minimumCharacters,
            120,
            "reacting to a single clause is what produced churning, half-thought cards"
        )
    }

    func testCustomConfigurationIsHonoured() {
        var custom = CopilotTurnAccumulator()
        custom.minimumCharacters = 10
        custom.maximumWait = 100

        XCTAssertEqual(custom.decide(accumulatedCharacters: 10, elapsed: 1), .waitForPause)
        XCTAssertEqual(custom.decide(accumulatedCharacters: 5, elapsed: 1), .hold)
        XCTAssertEqual(custom.decide(accumulatedCharacters: 5, elapsed: 100), .fireNow)
    }

    /// The tap's own throttle must not starve the accumulator: if slices
    /// arrived less often than the ceiling, the ceiling would always win and
    /// the pause logic would be dead code.
    func testTranscriptionArrivesFasterThanTheCeiling() {
        let configuration = LiveTranscriptionTapConfiguration()

        XCTAssertLessThan(
            configuration.windowDuration + configuration.minimumInterval,
            self.accumulator.maximumWait
        )
    }
}
