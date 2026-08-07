import Foundation

// MARK: - Trigger Policy

/// Decides when a new speech turn is worth an insight.
///
/// Pure and synchronous so the rule can be tested without a provider, a clock,
/// or a running meeting.
nonisolated struct CopilotInsightTrigger: Sendable {
    /// Below this, a turn is an acknowledgement ("right", "sure") rather than
    /// something to answer.
    var minimumCharacters = 25

    /// Floor between automatic insights, so a fast conversation cannot spin the
    /// provider continuously (`FR-011`).
    var minimumInterval: TimeInterval = 4

    /// - Parameters:
    ///   - lastFiredAt: media time of the previous automatic insight.
    ///   - now: media time of the turn being considered.
    func shouldFire(
        text: String,
        isLocalUser: Bool,
        lastFiredAt: MeetingMediaTime?,
        now: MeetingMediaTime
    ) -> Bool {
        // The copilot answers the other side. Reacting to the user's own speech
        // would suggest replies to themselves.
        guard !isLocalUser else { return false }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= self.minimumCharacters else { return false }

        guard let lastFiredAt else { return true }
        return (now.seconds - lastFiredAt.seconds) >= self.minimumInterval
    }
}

// MARK: - Provider Route

/// Where a copilot request should be sent, resolved once per session (AD-005).
nonisolated struct CopilotProviderRoute: Equatable, Sendable {
    let baseURL: String
    let model: String
    let apiKey: String
    let choice: CopilotProviderChoice

    var isUsable: Bool {
        !self.model.isEmpty && !self.baseURL.isEmpty
    }
}

// MARK: - Errors

nonisolated enum CopilotInsightError: Error, Equatable {
    case providerUnavailable
    case cancelled
    case emptyResponse
}

// MARK: - Engine

/// Turns context plus a profile into insight text, through the app's existing
/// LLM client.
///
/// Failure here is always contained: a provider that is down, misconfigured, or
/// slow produces a failed card and nothing more. It never touches capture,
/// transcription, or the session itself (`FR-012`, `SC-005`).
actor CopilotInsightEngine {
    private let client: LLMClient
    private let route: CopilotProviderRoute
    private let language: CopilotSeedLanguage

    private var inFlight: Task<String, Error>?
    private var lastAutomaticFireTime: MeetingMediaTime?

    let trigger: CopilotInsightTrigger

    init(
        client: LLMClient = .shared,
        route: CopilotProviderRoute,
        language: CopilotSeedLanguage,
        trigger: CopilotInsightTrigger = CopilotInsightTrigger()
    ) {
        self.client = client
        self.route = route
        self.language = language
        self.trigger = trigger
    }

    // MARK: - Automatic Insights

    /// Whether this turn warrants an automatic insight, per the trigger policy.
    func shouldFireAutomatically(text: String, isLocalUser: Bool, at time: MeetingMediaTime) -> Bool {
        self.trigger.shouldFire(
            text: text,
            isLocalUser: isLocalUser,
            lastFiredAt: self.lastAutomaticFireTime,
            now: time
        )
    }

    func recordAutomaticFire(at time: MeetingMediaTime) {
        self.lastAutomaticFireTime = time
    }

    // MARK: - Execution

    /// Runs a request, cancelling whatever was still in flight.
    ///
    /// Superseding rather than queueing is the point: by the time a stale answer
    /// arrives the conversation has moved on, and showing it would be worse than
    /// showing nothing (`FR-011`).
    func run(
        _ request: CopilotPromptBuilder.Request,
        profile: MeetingCopilotProfile,
        context: CopilotContextWindow,
        chatHistory: [CopilotChatMessage] = [],
        onChunk: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        guard self.route.isUsable else { throw CopilotInsightError.providerUnavailable }

        self.inFlight?.cancel()

        let messages = CopilotPromptBuilder.messages(
            for: request,
            profile: profile,
            context: context,
            language: self.language,
            chatHistory: chatHistory
        )

        let task = Task<String, Error> { [client, route] in
            var config = LLMClient.Config(
                messages: messages,
                model: route.model,
                baseURL: route.baseURL,
                apiKey: route.apiKey,
                streaming: onChunk != nil,
                temperature: 0.3,
                maxTokens: Self.maxTokens(for: request)
            )
            config.timeoutSeconds = Self.timeout(for: request)
            config.onContentChunk = onChunk

            let response = try await client.call(config)
            try Task.checkCancellation()

            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CopilotInsightError.emptyResponse }
            return text
        }

        self.inFlight = task
        defer { self.inFlight = nil }

        do {
            return try await task.value
        } catch is CancellationError {
            throw CopilotInsightError.cancelled
        }
    }

    func cancelInFlight() {
        self.inFlight?.cancel()
        self.inFlight = nil
    }

    // MARK: - Budgets

    /// A briefing is a document; everything else interrupts a live conversation
    /// and has to stay short.
    private static func maxTokens(for request: CopilotPromptBuilder.Request) -> Int {
        switch request {
        case .briefing: return 2000
        case .recap: return 600
        case .automaticInsight, .clarify, .lookUp, .chat: return 400
        }
    }

    private static func timeout(for request: CopilotPromptBuilder.Request) -> TimeInterval {
        switch request {
        case .briefing: return 120
        default: return 30
        }
    }
}
