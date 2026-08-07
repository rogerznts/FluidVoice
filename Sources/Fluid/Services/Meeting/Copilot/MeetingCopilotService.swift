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
    /// Explains why the copilot cannot produce anything, when that is the case.
    /// Shown in place of the stream rather than left blank.
    @Published private(set) var unavailableReason: String?

    // MARK: - Dependencies

    private let sessionID: MeetingSessionID
    private let language: CopilotSeedLanguage
    private let providerChoice: CopilotProviderChoice
    private let engine: CopilotInsightEngine
    private let engineTrigger = CopilotInsightTrigger()
    private let store: any MeetingCopilotArtifactStoring
    private let profileStore: MeetingCopilotProfileStore

    private var context = CopilotContextWindow()
    private var persistTask: Task<Void, Never>?

    /// Debounce for automatic insights.
    ///
    /// Live transcription arrives in ~3.5s slices, which are fragments of a
    /// sentence, not turns. Reacting to each one produced suggestions about
    /// half-finished thoughts. This waits for the speaker to actually pause.
    private var pendingInsightTask: Task<Void, Never>?
    /// Turns accumulated since the last insight, quoted together so the card
    /// reflects a thought rather than a fragment.
    private var turnsSinceLastInsight: [String] = []
    private var lastInsightAt: Date?
    /// When the current accumulation began. Without this the ceiling below has
    /// nothing to measure against before the first insight, so continuous
    /// speech kept cancelling the debounce and nothing ever fired.
    private var accumulationStartedAt: Date?
    /// Insight to update in place while the same topic continues, instead of
    /// stacking a new card per fragment.
    private var openInsightID: CopilotInsightID?
    /// Everything quoted into the open card so far, so a revision shows the
    /// whole stretch rather than only the newest fragment.
    private var openInsightQuotes: [String] = []

    /// How long the speaker must pause before a suggestion is produced.
    ///
    /// Must exceed the tap's transcription interval (~3.5s). At 2.5s it never
    /// waited for anything: every slice arrived after the debounce had already
    /// elapsed, so every fragment fired.
    private static let turnPause: TimeInterval = 7
    /// Ceiling for continuous speech, so a monologue still gets suggestions.
    private static let maxSilenceWait: TimeInterval = 20
    /// Within this window the same card is revised rather than replaced.
    private static let sameTopicWindow: TimeInterval = 90
    /// Enough accumulated speech to be worth a suggestion. A couple of clauses
    /// is not a thought.
    private static let minimumAccumulatedCharacters = 220

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
        self.pendingInsightTask?.cancel()
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

        guard self.unavailableReason == nil else { return }
        guard SettingsStore.shared.copilotInsightTrigger == .automatic else { return }
        guard !isLocalUser else { return }

        self.turnsSinceLastInsight.append(text)
        if self.accumulationStartedAt == nil {
            self.accumulationStartedAt = Date()
        }

        // Reschedule on every new fragment. The insight fires when speech stops
        // — or when the ceiling is reached, so a long monologue is not ignored.
        self.pendingInsightTask?.cancel()
        let since = self.lastInsightAt ?? self.accumulationStartedAt ?? Date()
        let waitedLongEnough = Date().timeIntervalSince(since) >= Self.maxSilenceWait

        if waitedLongEnough {
            await self.fireAccumulatedInsight(at: time)
            return
        }

        self.pendingInsightTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.turnPause * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.fireAccumulatedInsight(at: time)
        }
    }

    /// Produces one suggestion for everything accumulated since the last one.
    private func fireAccumulatedInsight(at time: MeetingMediaTime) async {
        let accumulated = self.turnsSinceLastInsight
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accumulated.isEmpty else { return }

        // Continue the open card while the topic is still running; start a new
        // one once the conversation has clearly moved on.
        let isRevision = self.openInsightID != nil
            && (self.insights.last?.id == self.openInsightID)
            && (self.insights.last?.anchor.seconds).map { time.seconds - $0 < Self.sameTopicWindow } ?? false

        // A revision inherits everything already quoted, so the card shows the
        // whole stretch of speech rather than only the newest fragment.
        var quotes = isRevision ? self.openInsightQuotes : []
        quotes.append(accumulated)
        let quoted = quotes.joined(separator: " ")

        // Hold until there is enough speech to reason about. Without this the
        // card churns on a clause at a time.
        guard quoted.count >= Self.minimumAccumulatedCharacters else {
            DebugLogger.shared.log(
                "MeetingCopilot: holding, \(quoted.count)/\(Self.minimumAccumulatedCharacters) chars accumulated",
                level: .info,
                source: "MeetingCopilot"
            )
            return
        }
        DebugLogger.shared.log(
            "MeetingCopilot: firing insight over \(quoted.count) chars (revision: \(isRevision))",
            level: .info,
            source: "MeetingCopilot"
        )

        self.turnsSinceLastInsight.removeAll()
        self.openInsightQuotes = quotes
        self.lastInsightAt = Date()
        self.accumulationStartedAt = nil
        await self.engine.recordAutomaticFire(at: time)

        await self.produceInsight(
            .automaticInsight,
            anchor: time,
            quoted: quoted,
            revising: isRevision ? self.openInsightID : nil
        )
    }

    func noteDroppedAudio(count: Int) {
        self.droppedAudioChunks = count
    }

    /// Records that no usable provider was resolved for this session.
    ///
    /// On-device inference needs Fluid Intelligence, which is not part of the
    /// public build — so on this build `.local` can never resolve, and saying
    /// so is more useful than an empty panel.
    func reportProviderUnavailable(choice: CopilotProviderChoice) {
        switch choice {
        case .local:
            self.unavailableReason = "On-device AI is not available in this build. Pick a cloud provider in Meeting Settings, or configure a local server such as Ollama or LM Studio under AI Enhancement."
        case .cloud:
            self.unavailableReason = "No cloud provider is configured. Set one up under AI Enhancement, then start the meeting again."
        }
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
        quoted: String,
        revising existingID: CopilotInsightID? = nil
    ) async {
        guard let profile = activeProfile else { return }

        var insight: CopilotInsight
        if let existingID, let index = insights.firstIndex(where: { $0.id == existingID }) {
            // Same topic still running: revise the card in place so the panel
            // reads as one developing thought instead of a stack of fragments.
            insight = self.insights[index]
            insight.anchor = anchor
            insight.quotedContext = quoted
            insight.state = .streaming
            insight.errorMessage = nil
            self.insights[index] = insight
        } else {
            insight = CopilotInsight(
                anchor: anchor,
                origin: request.origin ?? .automatic,
                format: profile.insightFormat,
                profileID: profile.id,
                situation: CopilotPromptBuilder.situationLabel(for: request, language: self.language),
                quotedContext: quoted,
                state: .streaming
            )
            self.insights.append(insight)
            if request.origin == .automatic {
                self.openInsightQuotes = [quoted]
            }
        }
        let insightID = insight.id
        if request.origin == .automatic {
            self.openInsightID = insightID
        }

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
        self.pendingInsightTask?.cancel()
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
