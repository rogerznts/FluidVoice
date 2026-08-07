@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T038. Parsing is where notes fail quietly: a model that drifts from
/// the requested format produces notes that look fine and say nothing.
final class CopilotNoteExtractorTests: XCTestCase {
    private let anchor = MeetingMediaTime(value: 600, timescale: 600)

    // MARK: - Parsing

    func testParsesEachNoteKind() {
        let response = """
        DECISION: Ship the migration on Friday
        ACTION: Marina sends the security questionnaire
        QUESTION: Who owns the rollback plan?
        """

        let notes = CopilotNoteExtractor.parse(response, anchor: self.anchor)

        XCTAssertEqual(notes.count, 3)
        XCTAssertEqual(notes.map(\.kind), [.decision, .actionItem, .openQuestion])
        XCTAssertEqual(notes.first?.text, "Ship the migration on Friday")
    }

    func testParsesPortuguesePrefixes() {
        let response = """
        DECISAO: Adiar o lançamento
        PENDÊNCIA: Roger revisa o contrato
        PERGUNTA: Quem aprova o orçamento?
        """

        let notes = CopilotNoteExtractor.parse(response, anchor: self.anchor)

        XCTAssertEqual(notes.map(\.kind), [.decision, .actionItem, .openQuestion])
        XCTAssertEqual(notes.last?.text, "Quem aprova o orçamento?")
    }

    /// Models bullet things whether or not you ask them to.
    func testStripsBulletsBeforeParsing() {
        let notes = CopilotNoteExtractor.parse("- DECISION: Keep the current vendor", anchor: self.anchor)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "Keep the current vendor")
    }

    /// The sentinel the prompt asks for when nothing was decided.
    func testEmptyMarkerYieldsNoNotes() {
        XCTAssertTrue(CopilotNoteExtractor.parse("EMPTY", anchor: self.anchor).isEmpty)
        XCTAssertTrue(CopilotNoteExtractor.parse("VAZIO", anchor: self.anchor).isEmpty)
        XCTAssertTrue(CopilotNoteExtractor.parse("  empty  ", anchor: self.anchor).isEmpty)
    }

    func testEmptyResponseYieldsNoNotes() {
        XCTAssertTrue(CopilotNoteExtractor.parse("", anchor: self.anchor).isEmpty)
        XCTAssertTrue(CopilotNoteExtractor.parse("   \n  ", anchor: self.anchor).isEmpty)
    }

    /// Prose without a prefix is dropped rather than filed under a guessed
    /// type — a wrong decision recorded as fact is worse than a missing one.
    func testUnprefixedProseIsDropped() {
        let response = """
        Here is a summary of the meeting.
        DECISION: Approve the budget
        The team seemed aligned overall.
        """

        let notes = CopilotNoteExtractor.parse(response, anchor: self.anchor)

        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes.first?.text, "Approve the budget")
    }

    func testPrefixWithNoTextIsDropped() {
        XCTAssertTrue(CopilotNoteExtractor.parse("DECISION:", anchor: self.anchor).isEmpty)
        XCTAssertTrue(CopilotNoteExtractor.parse("ACTION:    ", anchor: self.anchor).isEmpty)
    }

    func testNotesCarryTheAnchor() {
        let notes = CopilotNoteExtractor.parse("DECISION: Something", anchor: self.anchor)

        XCTAssertEqual(notes.first?.anchor, self.anchor)
    }

    // MARK: - Merging

    /// Notes are extracted repeatedly over a meeting, so the same decision
    /// surfaces more than once. Without dedup the list becomes a transcript of
    /// itself.
    func testMergeSkipsDuplicates() {
        let existing = CopilotNoteExtractor.parse("DECISION: Ship on Friday", anchor: self.anchor)
        let incoming = CopilotNoteExtractor.parse("DECISION: Ship on Friday", anchor: self.anchor)

        let merged = CopilotNoteExtractor.merge(incoming, into: existing)

        XCTAssertEqual(merged.count, 1)
    }

    func testMergeIgnoresCaseAndTrailingPeriod() {
        let existing = CopilotNoteExtractor.parse("ACTION: Send the contract.", anchor: self.anchor)
        let incoming = CopilotNoteExtractor.parse("ACTION: send the contract", anchor: self.anchor)

        XCTAssertEqual(CopilotNoteExtractor.merge(incoming, into: existing).count, 1)
    }

    /// Same text under a different kind is a different note, not a duplicate.
    func testMergeKeepsSameTextUnderDifferentKinds() {
        let existing = CopilotNoteExtractor.parse("DECISION: Review the contract", anchor: self.anchor)
        let incoming = CopilotNoteExtractor.parse("ACTION: Review the contract", anchor: self.anchor)

        XCTAssertEqual(CopilotNoteExtractor.merge(incoming, into: existing).count, 2)
    }

    func testMergeAppendsGenuinelyNewNotes() {
        let existing = CopilotNoteExtractor.parse("DECISION: Ship on Friday", anchor: self.anchor)
        let incoming = CopilotNoteExtractor.parse("QUESTION: Who signs off?", anchor: self.anchor)

        XCTAssertEqual(CopilotNoteExtractor.merge(incoming, into: existing).count, 2)
    }
}
