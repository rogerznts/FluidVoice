//
//  MeetingCopilotProfileStore.swift
//  Fluid
//
//  Persistence for meeting copilot profiles (live insight + briefing prompts)
//

import Combine
import Foundation

// MARK: - Profile Model

/// A meeting copilot profile: what the copilot pays attention to, how it writes
/// its insights, and how it formats the final briefing.
///
/// Deliberately a separate type from `SettingsStore.DictationPromptProfile`
/// rather than a new `PromptMode` case (AD-003). `PromptMode` drives dictation
/// prompt routing, including per-app bindings; adding `.meeting` there would
/// leak meeting behavior into the dictation path, which `FR-030` forbids.
nonisolated struct MeetingCopilotProfile: Codable, Identifiable, Hashable, Sendable {
    let id: CopilotProfileID
    var name: String
    /// Prompt driving live insight cards.
    var insightPrompt: String
    /// Prompt driving the post-meeting briefing.
    var briefingPrompt: String
    /// Whether insights are drafted to be spoken or offered as bullet points
    /// (DEC-COP-002).
    var insightFormat: CopilotInsightFormat
    /// SF Symbol shown in the picker.
    var symbolName: String
    /// `false` for the shipped seeds until the user edits one. Seeds stay
    /// editable — this only tracks whether the copy is still ours.
    var isCustomized: Bool
    var createdAt: Date
    var updatedAt: Date

    init(
        id: CopilotProfileID = UUID().uuidString,
        name: String,
        insightPrompt: String,
        briefingPrompt: String,
        insightFormat: CopilotInsightFormat,
        symbolName: String = "sparkles",
        isCustomized: Bool = true,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.insightPrompt = insightPrompt
        self.briefingPrompt = briefingPrompt
        self.insightFormat = insightFormat
        self.symbolName = symbolName
        self.isCustomized = isCustomized
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.insightPrompt = try container.decode(String.self, forKey: .insightPrompt)
        self.briefingPrompt = try container.decode(String.self, forKey: .briefingPrompt)
        self.insightFormat = try container.decodeIfPresent(CopilotInsightFormat.self, forKey: .insightFormat)
            ?? .supportingPoints
        self.symbolName = try container.decodeIfPresent(String.self, forKey: .symbolName) ?? "sparkles"
        self.isCustomized = try container.decodeIfPresent(Bool.self, forKey: .isCustomized) ?? true
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case insightPrompt
        case briefingPrompt
        case insightFormat
        case symbolName
        case isCustomized
        case createdAt
        case updatedAt
    }
}

// MARK: - Seed Language

/// Which language the shipped profile copy is written in (DEC-COP-001).
///
/// Resolved from the session's `languageCode`, so adding a language later does
/// not require a session schema migration.
nonisolated enum CopilotSeedLanguage: String, CaseIterable, Sendable {
    case portuguese = "pt"
    case english = "en"

    /// Maps a BCP-47-ish session language code onto a seed language, falling
    /// back to English for anything not shipped.
    static func resolve(from languageCode: String) -> CopilotSeedLanguage {
        let normalized = languageCode.lowercased()
        if normalized == "pt" || normalized.hasPrefix("pt-") || normalized.hasPrefix("pt_") {
            return .portuguese
        }
        return .english
    }
}

// MARK: - Store

/// Owns the copilot profile library: shipped seeds plus whatever the user adds.
///
/// Profiles are configuration, not session data, so `UserDefaults` is the right
/// home here — the "no UserDefaults" rule applies to meeting sessions, which
/// need crash recovery and unbounded growth (`CODE-006`).
final class MeetingCopilotProfileStore: ObservableObject {
    static let shared = MeetingCopilotProfileStore()

    private let defaults: UserDefaults

    private enum Keys {
        static let profiles = "MeetingCopilotProfiles"
        static let seededLanguages = "MeetingCopilotSeededLanguages"
        static let selectedProfileID = "MeetingCopilotSelectedProfileID"
    }

    @Published private(set) var profiles: [MeetingCopilotProfile] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.loadProfiles()
    }

    // MARK: - Seeding

    /// Installs the shipped profiles for `language` once.
    ///
    /// Idempotent by design: seeding again after the user deleted a seed would
    /// resurrect it, which reads as the app ignoring a deliberate choice.
    func seedIfNeeded(for language: CopilotSeedLanguage) {
        var seeded = Set(self.defaults.stringArray(forKey: Keys.seededLanguages) ?? [])
        guard !seeded.contains(language.rawValue) else { return }

        let existingIDs = Set(self.profiles.map(\.id))
        let newProfiles = Self.seeds(for: language).filter { !existingIDs.contains($0.id) }
        guard !newProfiles.isEmpty else {
            seeded.insert(language.rawValue)
            self.defaults.set(Array(seeded), forKey: Keys.seededLanguages)
            return
        }

        self.profiles.append(contentsOf: newProfiles)
        self.saveProfiles()

        seeded.insert(language.rawValue)
        self.defaults.set(Array(seeded), forKey: Keys.seededLanguages)
    }

    // MARK: - Queries

    func profile(id: CopilotProfileID) -> MeetingCopilotProfile? {
        self.profiles.first { $0.id == id }
    }

    func profiles(for language: CopilotSeedLanguage) -> [MeetingCopilotProfile] {
        let seedIDs = Set(Self.seeds(for: language).map(\.id))
        return self.profiles.filter { seedIDs.contains($0.id) || !$0.id.hasPrefix(Self.seedIDPrefix) }
    }

    var selectedProfileID: CopilotProfileID? {
        get { self.defaults.string(forKey: Keys.selectedProfileID) }
        set {
            self.objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.selectedProfileID)
        }
    }

    // MARK: - Mutations

    func add(_ profile: MeetingCopilotProfile) {
        self.profiles.append(profile)
        self.saveProfiles()
    }

    func update(_ profile: MeetingCopilotProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        updated.isCustomized = true
        updated.updatedAt = Date()
        self.profiles[index] = updated
        self.saveProfiles()
    }

    func delete(id: CopilotProfileID) {
        self.profiles.removeAll { $0.id == id }
        if self.selectedProfileID == id {
            self.selectedProfileID = self.profiles.first?.id
        }
        self.saveProfiles()
    }

    /// Copies a profile so the user can diverge from a seed without losing it.
    @discardableResult
    func duplicate(id: CopilotProfileID) -> MeetingCopilotProfile? {
        guard let source = profile(id: id) else { return nil }
        let copy = MeetingCopilotProfile(
            name: "\(source.name) copy",
            insightPrompt: source.insightPrompt,
            briefingPrompt: source.briefingPrompt,
            insightFormat: source.insightFormat,
            symbolName: source.symbolName
        )
        self.add(copy)
        return copy
    }

    // MARK: - Persistence

    private func loadProfiles() {
        guard let data = defaults.data(forKey: Keys.profiles) else { return }
        do {
            self.profiles = try JSONDecoder().decode([MeetingCopilotProfile].self, from: data)
        } catch {
            DebugLogger.shared.log("MeetingCopilotProfileStore: failed to decode profiles — \(error)")
        }
    }

    private func saveProfiles() {
        do {
            let data = try JSONEncoder().encode(self.profiles)
            self.defaults.set(data, forKey: Keys.profiles)
        } catch {
            DebugLogger.shared.log("MeetingCopilotProfileStore: failed to encode profiles — \(error)")
        }
    }
}

// MARK: - Shipped Profiles

extension MeetingCopilotProfileStore {
    /// Stable prefix marking a profile as one we shipped. Lets the store tell
    /// seeds apart from user-authored profiles without a separate flag.
    static let seedIDPrefix = "seed."

    static func seeds(for language: CopilotSeedLanguage) -> [MeetingCopilotProfile] {
        switch language {
        case .portuguese:
            return self.portugueseSeeds()
        case .english:
            return self.englishSeeds()
        }
    }

    private static func portugueseSeeds() -> [MeetingCopilotProfile] {
        [
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)technical-interview.pt",
                name: "Entrevista Técnica",
                insightPrompt: """
                Você acompanha uma entrevista técnica em tempo real, ajudando quem está sendo entrevistado.

                Quando o entrevistador fizer uma pergunta técnica, redija uma resposta que a pessoa possa \
                dizer em voz alta. Seja concreto: cite tecnologias, trade-offs e números quando fizer sentido. \
                Prefira uma resposta estruturada e curta a uma exaustiva.

                Não invente experiência profissional que não apareceu na conversa. Se a pergunta for vaga, \
                sugira a pergunta de esclarecimento que a pessoa deveria fazer antes de responder.
                """,
                briefingPrompt: """
                Produza um relatório da entrevista técnica com: perguntas feitas, resumo das respostas dadas, \
                tópicos onde a resposta ficou fraca ou incompleta, e o que estudar antes da próxima etapa.
                """,
                insightFormat: .draftedResponse,
                symbolName: "chevron.left.forwardslash.chevron.right",
                isCustomized: false
            ),
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)job-interview.pt",
                name: "Entrevista de Emprego",
                insightPrompt: """
                Você acompanha uma entrevista de emprego em tempo real, ajudando quem está sendo entrevistado.

                Quando o entrevistador fizer uma pergunta comportamental ou sobre trajetória, ofereça os pontos \
                que valeria cobrir na resposta — de preferência no formato situação, ação e resultado.

                Não redija a fala pronta e não invente fatos sobre a carreira da pessoa. Trabalhe apenas com o \
                que apareceu na conversa.
                """,
                briefingPrompt: """
                Produza um resumo da entrevista com: perguntas feitas, pontos que a pessoa cobriu bem, pontos \
                que ficaram vagos, sinais sobre a vaga e a empresa, e os próximos passos combinados.
                """,
                insightFormat: .supportingPoints,
                symbolName: "person.crop.rectangle",
                isCustomized: false
            ),
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)sales.pt",
                name: "Vendas",
                insightPrompt: """
                Você acompanha uma call comercial em tempo real, ajudando quem está vendendo.

                Quando o cliente levantar uma objeção ou fizer uma pergunta difícil, redija uma resposta que \
                trate a objeção de frente, com dado concreto quando ele tiver aparecido na conversa.

                Sinalize sinais de compra e sinais de risco. Não prometa preço, prazo ou funcionalidade que \
                não tenham sido mencionados.
                """,
                briefingPrompt: """
                Produza um resumo da call com: contexto e dor do cliente, objeções levantadas e como foram \
                tratadas, sinais de compra, riscos, e os próximos passos com responsável e prazo.
                """,
                insightFormat: .draftedResponse,
                symbolName: "chart.line.uptrend.xyaxis",
                isCustomized: false
            ),
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)lecture.pt",
                name: "Aula",
                insightPrompt: """
                Você acompanha uma aula em tempo real, ajudando quem está assistindo.

                Destaque os conceitos centrais conforme aparecem, com uma explicação curta de cada um. Quando \
                um termo técnico for usado sem definição, defina-o.

                Não redija falas. O objetivo é entender melhor, não participar.
                """,
                briefingPrompt: """
                Produza notas de aula com: conceitos apresentados e suas definições, exemplos usados, relações \
                entre os tópicos, e as dúvidas que ficaram em aberto.
                """,
                insightFormat: .supportingPoints,
                symbolName: "book",
                isCustomized: false
            ),
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)internal-meeting.pt",
                name: "Reunião Interna",
                insightPrompt: """
                Você acompanha uma reunião de trabalho em tempo real.

                Destaque decisões tomadas, pendências atribuídas e pontos que ficaram sem conclusão. Quando \
                alguém pedir um dado ou contexto que já apareceu antes na reunião, retome esse trecho.

                Não redija falas. Seja breve: quem está na reunião não tem tempo de ler parágrafos.
                """,
                briefingPrompt: """
                Produza uma ata com: participantes identificados, pauta tratada, decisões tomadas, pendências \
                com responsável e prazo, e questões que ficaram em aberto.
                """,
                insightFormat: .supportingPoints,
                symbolName: "person.3",
                isCustomized: false
            ),
        ]
    }

    private static func englishSeeds() -> [MeetingCopilotProfile] {
        [
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)technical-interview.en",
                name: "Technical Interview",
                insightPrompt: """
                You are following a technical interview in real time, helping the person being interviewed.

                When the interviewer asks a technical question, draft an answer they can say out loud. Be \
                concrete: name technologies, trade-offs, and numbers where they apply. Prefer a short \
                structured answer over an exhaustive one.

                Do not invent professional experience that has not come up in the conversation. If the \
                question is vague, suggest the clarifying question they should ask first.
                """,
                briefingPrompt: """
                Produce a technical interview report covering: questions asked, a summary of the answers \
                given, topics where the answer was weak or incomplete, and what to study before the next round.
                """,
                insightFormat: .draftedResponse,
                symbolName: "chevron.left.forwardslash.chevron.right",
                isCustomized: false
            ),
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)job-interview.en",
                name: "Job Interview",
                insightPrompt: """
                You are following a job interview in real time, helping the person being interviewed.

                When the interviewer asks a behavioral or career question, offer the points worth covering in \
                the answer — ideally shaped as situation, action, and result.

                Do not draft the words for them, and do not invent facts about their career. Work only with \
                what has come up in the conversation.
                """,
                briefingPrompt: """
                Produce an interview summary covering: questions asked, points the candidate covered well, \
                points that stayed vague, signals about the role and company, and agreed next steps.
                """,
                insightFormat: .supportingPoints,
                symbolName: "person.crop.rectangle",
                isCustomized: false
            ),
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)sales.en",
                name: "Sales",
                insightPrompt: """
                You are following a sales call in real time, helping the person selling.

                When the prospect raises an objection or asks a hard question, draft an answer that meets the \
                objection head-on, with concrete data when it has come up in the conversation.

                Flag buying signals and risk signals. Never promise pricing, timelines, or features that have \
                not been mentioned.
                """,
                briefingPrompt: """
                Produce a call summary covering: customer context and pain, objections raised and how they \
                were handled, buying signals, risks, and next steps with owner and date.
                """,
                insightFormat: .draftedResponse,
                symbolName: "chart.line.uptrend.xyaxis",
                isCustomized: false
            ),
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)lecture.en",
                name: "Lecture",
                insightPrompt: """
                You are following a lecture in real time, helping the person attending.

                Surface the core concepts as they appear, each with a short explanation. When a technical term \
                is used without being defined, define it.

                Do not draft speech. The goal is understanding, not participating.
                """,
                briefingPrompt: """
                Produce lecture notes covering: concepts presented and their definitions, examples used, how \
                the topics relate, and questions left open.
                """,
                insightFormat: .supportingPoints,
                symbolName: "book",
                isCustomized: false
            ),
            MeetingCopilotProfile(
                id: "\(self.seedIDPrefix)internal-meeting.en",
                name: "Internal Meeting",
                insightPrompt: """
                You are following a work meeting in real time.

                Surface decisions made, action items assigned, and points left unresolved. When someone asks \
                for a fact or context that came up earlier in the meeting, bring that passage back.

                Do not draft speech. Be brief: people in a meeting cannot read paragraphs.
                """,
                briefingPrompt: """
                Produce minutes covering: identified participants, agenda covered, decisions made, action \
                items with owner and date, and open questions.
                """,
                insightFormat: .supportingPoints,
                symbolName: "person.3",
                isCustomized: false
            ),
        ]
    }
}
