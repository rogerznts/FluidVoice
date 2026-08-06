import Foundation

/// Builds the messages sent to the LLM for each kind of copilot request.
///
/// One place decides how a profile, an output format, and a session language
/// become a prompt — so behaviour stays consistent across automatic insights,
/// quick actions, chat, and briefings.
nonisolated enum CopilotPromptBuilder {
    // MARK: - Request Kinds

    nonisolated enum Request: Equatable, Sendable {
        /// Fired by the engine at the end of a speech turn.
        case automaticInsight
        case clarify
        case recap
        case lookUp
        case chat(question: String)
        case briefing

        var origin: CopilotInsightOrigin? {
            switch self {
            case .automaticInsight: return .automatic
            case .clarify: return .actionClarify
            case .recap: return .actionRecap
            case .lookUp: return .actionLookUp
            case .chat, .briefing: return nil
            }
        }
    }

    // MARK: - Building

    static func messages(
        for request: Request,
        profile: MeetingCopilotProfile,
        context: CopilotContextWindow,
        language: CopilotSeedLanguage,
        chatHistory: [CopilotChatMessage] = []
    ) -> [[String: Any]] {
        var messages: [[String: Any]] = [
            ["role": "system", "content": self.systemPrompt(for: request, profile: profile, language: language)],
        ]

        // Chat carries its own history; other requests are one-shot over the
        // window, which keeps their cost flat across a long meeting.
        if case .chat = request {
            for message in chatHistory.suffix(10) {
                messages.append([
                    "role": message.role == .user ? "user" : "assistant",
                    "content": message.content,
                ])
            }
        }

        messages.append(["role": "user", "content": self.userPrompt(for: request, context: context, language: language)])
        return messages
    }

    // MARK: - System Prompt

    static func systemPrompt(
        for request: Request,
        profile: MeetingCopilotProfile,
        language: CopilotSeedLanguage
    ) -> String {
        var parts: [String] = []

        switch request {
        case .briefing:
            parts.append(profile.briefingPrompt)
        default:
            parts.append(profile.insightPrompt)
        }

        parts.append(self.formatInstruction(for: request, format: profile.insightFormat, language: language))
        parts.append(self.languageInstruction(language))
        parts.append(self.honestyInstruction(for: request, language: language))

        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// How the answer should be shaped (`DEC-COP-002`, `FR-033`).
    private static func formatInstruction(
        for request: Request,
        format: CopilotInsightFormat,
        language: CopilotSeedLanguage
    ) -> String {
        // Recap and briefing are summaries by nature; the drafted/bullet choice
        // does not apply to them.
        switch request {
        case .recap, .briefing:
            return ""
        case .chat:
            return language == .portuguese
                ? "Responda de forma direta e curta. Quem pergunta está no meio de uma reunião."
                : "Answer directly and briefly. The person asking is in the middle of a meeting."
        case .automaticInsight, .clarify, .lookUp:
            break
        }

        switch (format, language) {
        case (.draftedResponse, .portuguese):
            return """
            Escreva uma resposta pronta para ser dita em voz alta, na primeira pessoa. \
            No máximo 4 frases. Sem preâmbulo, sem meta-comentário — só a fala.
            """
        case (.draftedResponse, .english):
            return """
            Write a reply ready to be said out loud, in the first person. Four sentences at most. \
            No preamble, no meta-commentary — just the words to say.
            """
        case (.supportingPoints, .portuguese):
            return """
            Responda em no máximo 4 tópicos curtos, um por linha, começando com "- ". \
            São pontos de apoio para a pessoa formular a própria resposta, não uma fala pronta.
            """
        case (.supportingPoints, .english):
            return """
            Answer in at most 4 short bullets, one per line, starting with "- ". \
            These are points to build an answer from, not words to read aloud.
            """
        }
    }

    private static func languageInstruction(_ language: CopilotSeedLanguage) -> String {
        switch language {
        case .portuguese:
            return "Responda sempre em português do Brasil."
        case .english:
            return "Always answer in English."
        }
    }

    /// Guards against the two ways this feature could mislead: inventing facts,
    /// and implying a web lookup that never happened (`FR-013`, premissa A-04).
    private static func honestyInstruction(
        for request: Request,
        language: CopilotSeedLanguage
    ) -> String {
        let base = language == .portuguese
            ? "Baseie-se apenas no que foi dito na reunião. Não invente fatos, números ou nomes que não apareceram."
            : "Ground everything in what was actually said in the meeting. Do not invent facts, numbers, or names that did not appear."

        guard case .lookUp = request else { return base }

        let lookUpCaveat = language == .portuguese
            ? """
            Você NÃO tem acesso à internet. Responda a partir do seu próprio conhecimento e \
            diga explicitamente que não consultou fontes externas.
            """
            : """
            You have NO internet access. Answer from your own knowledge and say plainly that you \
            did not consult any external source.
            """
        return "\(base)\n\n\(lookUpCaveat)"
    }

    // MARK: - User Prompt

    static func userPrompt(
        for request: Request,
        context: CopilotContextWindow,
        language: CopilotSeedLanguage
    ) -> String {
        let transcript = context.promptContext()
        let isPortuguese = language == .portuguese

        switch request {
        case .automaticInsight:
            let latest = context.latestEntry?.text ?? ""
            let instruction = isPortuguese
                ? "A última fala foi:\n\"\(latest)\"\n\nResponda a ela."
                : "The most recent thing said was:\n\"\(latest)\"\n\nRespond to it."
            return "\(transcript)\n\n\(instruction)"

        case .clarify:
            return isPortuguese
                ? "\(transcript)\n\nExplique de forma simples o último ponto discutido."
                : "\(transcript)\n\nExplain the last point discussed, in plain terms."

        case .recap:
            return isPortuguese
                ? "\(transcript)\n\nResuma o que foi tratado até aqui, organizado por tópico."
                : "\(transcript)\n\nSummarise what has been covered so far, organised by topic."

        case .lookUp:
            let latest = context.latestEntry?.text ?? ""
            return isPortuguese
                ? "\(transcript)\n\nExplique os termos ou conceitos que apareceram em:\n\"\(latest)\""
                : "\(transcript)\n\nExplain the terms or concepts that came up in:\n\"\(latest)\""

        case let .chat(question):
            return "\(transcript)\n\n\(isPortuguese ? "Pergunta" : "Question"): \(question)"

        case .briefing:
            return isPortuguese
                ? "Transcrição completa da reunião:\n\n\(transcript)\n\nProduza o documento final."
                : "Full meeting transcript:\n\n\(transcript)\n\nProduce the final document."
        }
    }

    // MARK: - Card Metadata

    /// Short label describing what the card is reacting to, shown above the
    /// quoted context.
    static func situationLabel(for request: Request, language: CopilotSeedLanguage) -> String {
        let isPortuguese = language == .portuguese
        switch request {
        case .automaticInsight:
            return isPortuguese ? "Sugestão" : "Suggestion"
        case .clarify:
            return isPortuguese ? "Esclarecimento" : "Clarification"
        case .recap:
            return isPortuguese ? "Recapitulação" : "Recap"
        case .lookUp:
            return isPortuguese ? "Consulta" : "Look-up"
        case .chat:
            return isPortuguese ? "Resposta" : "Answer"
        case .briefing:
            return isPortuguese ? "Briefing" : "Briefing"
        }
    }
}
