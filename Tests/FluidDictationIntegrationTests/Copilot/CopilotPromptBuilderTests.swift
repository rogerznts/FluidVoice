@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T023: prompts must vary by profile, output format, and session
/// language — the three things `DEC-COP-001` and `DEC-COP-002` promise.
final class CopilotPromptBuilderTests: XCTestCase {
    private func makeProfile(
        format: CopilotInsightFormat,
        insight: String = "You are following a technical interview.",
        briefing: String = "Produce an interview report."
    ) -> MeetingCopilotProfile {
        MeetingCopilotProfile(
            name: "Test",
            insightPrompt: insight,
            briefingPrompt: briefing,
            insightFormat: format
        )
    }

    private func makeContext() -> CopilotContextWindow {
        var window = CopilotContextWindow()
        window.append(
            speaker: "Them",
            text: "How would you scale this to ten million messages per second?",
            time: MeetingMediaTime(value: 600, timescale: 600),
            isLocalUser: false
        )
        return window
    }

    // MARK: - Format

    func testDraftedResponseAsksForSpokenReply() {
        let prompt = CopilotPromptBuilder.systemPrompt(
            for: .automaticInsight,
            profile: self.makeProfile(format: .draftedResponse),
            language: .english
        )

        XCTAssertTrue(prompt.contains("said out loud"))
        XCTAssertFalse(prompt.contains("bullets"))
    }

    func testSupportingPointsAsksForBullets() {
        let prompt = CopilotPromptBuilder.systemPrompt(
            for: .automaticInsight,
            profile: self.makeProfile(format: .supportingPoints),
            language: .english
        )

        XCTAssertTrue(prompt.contains("bullets"))
        XCTAssertFalse(prompt.contains("said out loud"))
    }

    /// A recap is a summary by nature — the drafted/bullet choice does not
    /// apply, and forcing it would distort the output.
    func testRecapIgnoresInsightFormat() {
        let drafted = CopilotPromptBuilder.systemPrompt(
            for: .recap,
            profile: self.makeProfile(format: .draftedResponse),
            language: .english
        )
        let bullets = CopilotPromptBuilder.systemPrompt(
            for: .recap,
            profile: self.makeProfile(format: .supportingPoints),
            language: .english
        )

        XCTAssertEqual(drafted, bullets)
    }

    // MARK: - Language

    func testLanguageDrivesPromptLanguage() {
        let profile = self.makeProfile(format: .supportingPoints)

        let portuguese = CopilotPromptBuilder.systemPrompt(
            for: .automaticInsight,
            profile: profile,
            language: .portuguese
        )
        let english = CopilotPromptBuilder.systemPrompt(
            for: .automaticInsight,
            profile: profile,
            language: .english
        )

        XCTAssertTrue(portuguese.contains("português do Brasil"))
        XCTAssertTrue(english.contains("Always answer in English"))
        XCTAssertNotEqual(portuguese, english)
    }

    func testUserPromptFollowsLanguage() {
        let context = self.makeContext()

        let portuguese = CopilotPromptBuilder.userPrompt(for: .recap, context: context, language: .portuguese)
        let english = CopilotPromptBuilder.userPrompt(for: .recap, context: context, language: .english)

        XCTAssertTrue(portuguese.contains("Resuma"))
        XCTAssertTrue(english.contains("Summarise"))
    }

    // MARK: - Profile

    func testInsightAndBriefingUseDifferentProfilePrompts() {
        let profile = self.makeProfile(
            format: .supportingPoints,
            insight: "INSIGHT_MARKER",
            briefing: "BRIEFING_MARKER"
        )

        let insight = CopilotPromptBuilder.systemPrompt(for: .automaticInsight, profile: profile, language: .english)
        let briefing = CopilotPromptBuilder.systemPrompt(for: .briefing, profile: profile, language: .english)

        XCTAssertTrue(insight.contains("INSIGHT_MARKER"))
        XCTAssertFalse(insight.contains("BRIEFING_MARKER"))
        XCTAssertTrue(briefing.contains("BRIEFING_MARKER"))
        XCTAssertFalse(briefing.contains("INSIGHT_MARKER"))
    }

    // MARK: - Honesty Guards

    /// `FR-013` and premissa A-04: the product must not imply a web search it
    /// never performed.
    func testLookUpDeclaresNoInternetAccess() {
        let prompt = CopilotPromptBuilder.systemPrompt(
            for: .lookUp,
            profile: self.makeProfile(format: .supportingPoints),
            language: .english
        )

        XCTAssertTrue(prompt.contains("NO internet access"))
        XCTAssertTrue(prompt.lowercased().contains("did not consult"))
    }

    func testLookUpCaveatIsLocalised() {
        let prompt = CopilotPromptBuilder.systemPrompt(
            for: .lookUp,
            profile: self.makeProfile(format: .supportingPoints),
            language: .portuguese
        )

        XCTAssertTrue(prompt.contains("NÃO tem acesso à internet"))
    }

    func testEveryRequestGroundsAnswersInTheMeeting() {
        let profile = self.makeProfile(format: .supportingPoints)
        let requests: [CopilotPromptBuilder.Request] = [
            .automaticInsight, .clarify, .recap, .lookUp, .chat(question: "q"), .briefing,
        ]

        for request in requests {
            let prompt = CopilotPromptBuilder.systemPrompt(for: request, profile: profile, language: .english)
            XCTAssertTrue(
                prompt.contains("Do not invent facts"),
                "\(request) is missing the no-fabrication guard"
            )
        }
    }

    // MARK: - Messages

    func testMessagesStartWithSystemAndEndWithUser() {
        let messages = CopilotPromptBuilder.messages(
            for: .automaticInsight,
            profile: self.makeProfile(format: .draftedResponse),
            context: self.makeContext(),
            language: .english
        )

        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.first?["role"] as? String, "system")
        XCTAssertEqual(messages.last?["role"] as? String, "user")
    }

    func testChatCarriesPriorHistory() {
        let history = [
            CopilotChatMessage(role: .user, content: "earlier question"),
            CopilotChatMessage(role: .assistant, content: "earlier answer"),
        ]

        let messages = CopilotPromptBuilder.messages(
            for: .chat(question: "follow up"),
            profile: self.makeProfile(format: .supportingPoints),
            context: self.makeContext(),
            language: .english,
            chatHistory: history
        )

        let contents = messages.compactMap { $0["content"] as? String }
        XCTAssertTrue(contents.contains("earlier question"))
        XCTAssertTrue(contents.contains("earlier answer"))
        XCTAssertTrue(contents.last?.contains("follow up") == true)
    }

    /// One-shot requests stay one-shot, which is what keeps their cost flat
    /// across a long meeting.
    func testNonChatRequestsDoNotCarryHistory() {
        let history = [CopilotChatMessage(role: .user, content: "UNRELATED_MARKER")]

        let messages = CopilotPromptBuilder.messages(
            for: .automaticInsight,
            profile: self.makeProfile(format: .draftedResponse),
            context: self.makeContext(),
            language: .english,
            chatHistory: history
        )

        let contents = messages.compactMap { $0["content"] as? String }.joined()
        XCTAssertFalse(contents.contains("UNRELATED_MARKER"))
    }

    func testUserPromptCarriesTheLatestTurn() {
        let prompt = CopilotPromptBuilder.userPrompt(
            for: .automaticInsight,
            context: self.makeContext(),
            language: .english
        )

        XCTAssertTrue(prompt.contains("ten million messages per second"))
    }

    // MARK: - Card Labels

    func testSituationLabelsAreLocalised() {
        XCTAssertEqual(CopilotPromptBuilder.situationLabel(for: .recap, language: .portuguese), "Recapitulação")
        XCTAssertEqual(CopilotPromptBuilder.situationLabel(for: .recap, language: .english), "Recap")
    }

    func testRequestOriginMapping() {
        XCTAssertEqual(CopilotPromptBuilder.Request.automaticInsight.origin, .automatic)
        XCTAssertEqual(CopilotPromptBuilder.Request.clarify.origin, .actionClarify)
        XCTAssertEqual(CopilotPromptBuilder.Request.recap.origin, .actionRecap)
        XCTAssertEqual(CopilotPromptBuilder.Request.lookUp.origin, .actionLookUp)
        XCTAssertNil(CopilotPromptBuilder.Request.briefing.origin)
    }
}
