import Combine
import Foundation

/// Owns the copilot for one meeting: context, engine, artifacts, and the state
/// the panel observes.
///
/// Created by `MeetingSessionCoordinator` when a session starts and torn down
/// when it ends (AD-004). Not a singleton — only one meeting can be active
/// (`STATE-007`), and tying the lifetime to the session removes a whole class
/// of orphaned-state bugs.
@MainActor
final class MeetingCopilotService: ObservableObject {
    // MARK: - Published State

    @Published private(set) var insights: [CopilotInsight] = []
    @Published private(set) var chatMessages: [CopilotChatMessage] = []
    @Published private(set) var notes: [CopilotNote] = []
    @Published private(set) var briefings: [CopilotBriefing] = []
    @Published private(set) var activeProfile: MeetingCopilotProfile?
    @Published private(set) var isBusy = false
    /// Set when the live transcript is degraded because audio was dropped.
    @Published private(set) var droppedAudioChunks = 0

    // MARK: - Dependencies

    private let sessionID: MeetingSessionID
    private let language: CopilotSeedLanguage
    private let providerChoice: CopilotProviderChoice
    private let engine: CopilotInsightEngine
    private let store: any MeetingCopilotArtifactStoring
    private let profileStore: MeetingCopilotProfileStore

    private var context = CopilotContextWindow()
    private var persistTask: Task<Void, Never>?

    // MARK: - Init

    init(
        sessionID: MeetingSessionID,
        language: CopilotSeedLanguage,
        providerChoice: CopilotProviderChoice,
        route: CopilotProviderRoute,
        profileStore: MeetingCopilotProfileStore = .shared,
        store: any MeetingCopilotArtifactStoring = MeetingSessionStore.shared,
        client: LLMClient = .shared
    ) {
        self.sessionID = sessionID
        self.language = language
        self.providerChoice = providerChoice
        self.profileStore = profileStore
        self.store = store
        self.engine = CopilotInsightEngine(client: client, route: route, language: language)

        profileStore.seedIfNeeded(for: language)
        let preferredID = profileStore.selectedProfileID ?? SettingsStore.shared.defaultCopilotProfileID
        self.activeProfile = preferredID.flatMap { profileStore.profile(id: $0) }
            ?? profileStore.profiles.first
    }

    deinit {
        self.persistTask?.cancel()
    }

    // MARK: - Profile

    /// Switching mid-meeting affects only what comes next; existing cards keep
    /// the profile that produced them (`FR-010`).
    func selectProfile(_ profile: MeetingCopilotProfile) {
        self.activeProfile = profile
        self.profileStore.selectedProfileID = profile.id
    }

    // MARK: - Transcript Intake

    /// Feeds a transcript turn into the context and fires an automatic insight
    /// when the trigger policy allows.
    func ingestTranscript(
        speaker: String,
        text: String,
        time: MeetingMediaTime,
        isLocalUser: Bool
    ) async {
        self.context.append(speaker: speaker, text: text, time: time, isLocalUser: isLocalUser)

        guard SettingsStore.shared.copilotInsightTrigger == .automatic else { return }
        guard await self.engine.shouldFireAutomatically(
            text: text,
            isLocalUser: isLocalUser,
            at: time
        ) else { return }

        await self.engine.recordAutomaticFire(at: time)
        await self.produceInsight(.automaticInsight, anchor: time, quoted: text)
    }

    func noteDroppedAudio(count: Int) {
        self.droppedAudioChunks = count
    }

    // MARK: - Actions

    func runQuickAction(_ request: CopilotPromptBuilder.Request) async {
        let anchor = self.context.latestEntry?.time ?? MeetingMediaTime(value: 0, timescale: 600)
        await self.produceInsight(request, anchor: anchor, quoted: self.context.latestEntry?.text ?? "")
    }

    func sendChatMessage(_ question: String) async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let profile = activeProfile else { return }

        let anchor = self.context.latestEntry?.time
        self.chatMessages.append(CopilotChatMessage(role: .user, content: trimmed, anchor: anchor))

        var reply = CopilotChatMessage(role: .assistant, content: "", anchor: anchor)
        self.chatMessages.append(reply)
        let replyID = reply.id

        self.isBusy = true
        defer { isBusy = false }

        do {
            let history = Array(self.chatMessages.dropLast(2))
            let text = try await engine.run(
                .chat(question: trimmed),
                profile: profile,
                context: self.context,
                chatHistory: history
            )
            reply.content = text
        } catch {
            reply.errorMessage = Self.userFacingMessage(for: error)
        }

        if let index = chatMessages.firstIndex(where: { $0.id == replyID }) {
            self.chatMessages[index] = reply
        }
        self.schedulePersist()
    }

    // MARK: - Insight Production

    private func produceInsight(
        _ request: CopilotPromptBuilder.Request,
        anchor: MeetingMediaTime,
        quoted: String
    ) async {
        guard let profile = activeProfile else { return }

        var insight = CopilotInsight(
            anchor: anchor,
            origin: request.origin ?? .automatic,
            format: profile.insightFormat,
            profileID: profile.id,
            situation: CopilotPromptBuilder.situationLabel(for: request, language: self.language),
            quotedContext: quoted,
            state: .streaming
        )
        self.insights.append(insight)
        let insightID = insight.id

        self.isBusy = true
        defer { isBusy = false }

        do {
            let text = try await engine.run(request, profile: profile, context: self.context)
            insight.body = text
            insight.state = .complete
        } catch CopilotInsightError.cancelled {
            // Superseded by a fresher request; drop the card rather than leave a
            // stale one behind.
            self.insights.removeAll { $0.id == insightID }
            return
        } catch {
            insight.state = .failed
            insight.errorMessage = Self.userFacingMessage(for: error)
        }

        if let index = insights.firstIndex(where: { $0.id == insightID }) {
            self.insights[index] = insight
        }
        self.schedulePersist()
    }

    /// Provider problems are shown on the card and nowhere else. Capture,
    /// transcription, and the session carry on untouched (`FR-012`).
    private static func userFacingMessage(for error: Error) -> String {
        switch error {
        case CopilotInsightError.providerUnavailable:
            return "No AI provider is configured for the copilot."
        case CopilotInsightError.emptyResponse:
            return "The provider returned an empty response."
        case CopilotInsightError.cancelled:
            return "Superseded by a newer request."
        default:
            return (error as? LocalizedError)?.errorDescription ?? "The copilot request failed."
        }
    }

    // MARK: - Persistence

    /// Debounced so a burst of insights does not turn into a burst of disk
    /// writes during a live meeting.
    private func schedulePersist() {
        self.persistTask?.cancel()
        self.persistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await self?.persist()
        }
    }

    func persist() async {
        let artifacts = CopilotSessionArtifacts(
            sessionID: self.sessionID,
            providerChoice: self.providerChoice,
            initialProfileID: self.activeProfile?.id,
            insights: self.insights,
            chatMessages: self.chatMessages,
            notes: self.notes,
            briefings: self.briefings
        )
        do {
            try await self.store.saveArtifacts(artifacts)
        } catch {
            DebugLogger.shared.log(
                "MeetingCopilotService: failed to persist artifacts — \(error.localizedDescription)",
                level: .warning,
                source: "MeetingCopilot"
            )
        }
    }

    /// Flushes pending work at the end of a session.
    func finish() async {
        self.persistTask?.cancel()
        await self.engine.cancelInFlight()
        await self.persist()
    }

    func restore(_ artifacts: CopilotSessionArtifacts) {
        self.insights = artifacts.insights
        self.chatMessages = artifacts.chatMessages
        self.notes = artifacts.notes
        self.briefings = artifacts.briefings
    }
}

// MARK: - Route Resolution

extension CopilotProviderRoute {
    /// Resolves where copilot requests go, honouring the local-first default
    /// (`FR-025`) and the explicit opt-in required for cloud (`FR-026`).
    @MainActor
    static func resolve(choice: CopilotProviderChoice, settings: SettingsStore = .shared) -> Self {
        switch choice {
        case .local:
            let route = DictationProviderRoute.privateAIRoute(settings: settings)
            return Self(baseURL: route.baseURL, model: route.model, apiKey: route.apiKey, choice: .local)
        case .cloud:
            let route = DictationProviderRoute.resolve(settings: settings)
            return Self(baseURL: route.baseURL, model: route.model, apiKey: route.apiKey, choice: .cloud)
        }
    }
}
