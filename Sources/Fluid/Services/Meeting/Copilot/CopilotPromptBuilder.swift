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
        /// Grounded search against the open internet.
        case webSearch
        case chat(question: String)
        /// Structured notes: decisions, action items, open questions.
        case notes
        case briefing

        var origin: CopilotInsightOrigin? {
            switch self {
            case .automaticInsight: return .automatic
            case .clarify: return .actionClarify
            case .recap: return .actionRecap
            case .lookUp: return .actionLookUp
            case .webSearch: return .actionWebSearch
            case .chat, .briefing, .notes: return nil
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
        case .notes:
            // Parsed line by line, so the shape is not cosmetic.
            return language == .portuguese
                ? """
                Liste apenas o que foi efetivamente dito, uma linha por item, no formato:
                DECISAO: <texto>
                PENDENCIA: <texto>
                PERGUNTA: <texto>
                Se não houver nada de um tipo, omita. Se não houver nada de nenhum, responda VAZIO.
                """
                : """
                List only what was actually said, one line per item, in the format:
                DECISION: <text>
                ACTION: <text>
                QUESTION: <text>
                Omit a type when there is nothing for it. If there is nothing at all, answer EMPTY.
                """
        case .chat:
            return language == .portuguese
                ? "Responda de forma direta e curta. Quem pergunta está no meio de uma reunião."
                : "Answer directly and briefly. The person asking is in the middle of a meeting."
        case .webSearch:
            return language == .portuguese
                ? "Responda em no máximo 4 frases, citando o que as fontes dizem. Se as fontes contradizem o que foi falado na reunião, diga isso explicitamente."
                : "Answer in at most 4 sentences, citing what the sources say. If the sources contradict what was said in the meeting, say so explicitly."
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
            Escreva no máximo 3 frases curtas com a leitura mais útil do momento: o que está \
            realmente em jogo, uma tensão ou contradição que valha notar, ou a pergunta que \
            ninguém fez ainda. Só use lista quando forem mesmo itens paralelos.

            Não resuma o que acabou de ser dito — quem está na reunião ouviu. Acrescente algo.
            """
        case (.supportingPoints, .english):
            return """
            Write at most 3 short sentences with the most useful read on the moment: what is \
            actually at stake, a tension or contradiction worth noticing, or the question \
            nobody has asked yet. Use a list only when the items are genuinely parallel.

            Do not summarise what was just said — the person heard it. Add something.
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
            // The whole recent stretch, not just the last fragment: live
            // transcription arrives in slices, and a slice on its own is half a
            // thought.
            let instruction = isPortuguese
                ? "Considere os últimos turnos acima como um único trecho da conversa e traga a leitura mais útil sobre ele."
                : "Treat the last few turns above as one stretch of conversation, and give the most useful read on it."
            return "\(transcript)\n\n\(instruction)"

        case .clarify:
            return isPortuguese
                ? "\(transcript)\n\nExplique de forma simples o trecho mais recente acima — o assunto que está sendo tratado agora, não apenas a última frase."
                : "\(transcript)\n\nExplain the most recent stretch above in plain terms — the topic being discussed now, not just the final sentence."

        case .recap:
            return isPortuguese
                ? "\(transcript)\n\nResuma o que foi tratado até aqui, organizado por tópico."
                : "\(transcript)\n\nSummarise what has been covered so far, organised by topic."

        case .lookUp:
            return isPortuguese
                ? "\(transcript)\n\nExplique os termos, nomes ou conceitos que apareceram no trecho mais recente acima."
                : "\(transcript)\n\nExplain the terms, names, or concepts that came up in the most recent stretch above."

        case .webSearch:
            return isPortuguese
                ? "\(transcript)\n\nPesquise na internet sobre o trecho mais recente acima: verifique as afirmações feitas e traga informação adicional relevante."
                : "\(transcript)\n\nSearch the web about the most recent stretch above: check the claims made and bring relevant additional information."

        case let .chat(question):
            return "\(transcript)\n\n\(isPortuguese ? "Pergunta" : "Question"): \(question)"

        case .notes:
            return isPortuguese
                ? "\(transcript)\n\nExtraia decisões, pendências e perguntas em aberto do trecho acima."
                : "\(transcript)\n\nExtract decisions, action items, and open questions from the stretch above."

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
        case .webSearch:
            return isPortuguese ? "Pesquisa na web" : "Web search"
        case .chat:
            return isPortuguese ? "Resposta" : "Answer"
        case .notes:
            return isPortuguese ? "Notas" : "Notes"
        case .briefing:
            return isPortuguese ? "Briefing" : "Briefing"
        }
    }
}
