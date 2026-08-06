import Foundation

// MARK: - Identifiers

typealias CopilotInsightID = UUID
typealias CopilotChatMessageID = UUID
typealias CopilotNoteID = UUID
typealias CopilotBriefingID = UUID
typealias CopilotProfileID = String

// MARK: - Provider Choice

/// Where copilot inference runs for a session.
///
/// Fixed before Start and recorded on the session: switching mid-meeting would
/// send speech to a destination the user did not consent to for the earlier part
/// of the conversation (AD-005, FR-026).
nonisolated enum CopilotProviderChoice: String, Codable, CaseIterable, Sendable {
    /// On-device model. The default, and the only mode where no meeting speech
    /// leaves the Mac.
    case local
    /// The cloud provider configured in AI Enhancement. Requires explicit opt-in.
    case cloud

    var leavesDevice: Bool {
        self == .cloud
    }
}

// MARK: - Insight

/// What produced an entry in the copilot stream.
nonisolated enum CopilotInsightOrigin: String, Codable, Sendable {
    /// Fired by the engine at the end of a relevant speech turn.
    case automatic
    /// The user pressed Clarify.
    case actionClarify
    /// The user pressed Recap.
    case actionRecap
    /// The user pressed Look up.
    case actionLookUp
}

/// How a profile wants its insights written (DEC-COP-002, FR-033).
nonisolated enum CopilotInsightFormat: String, Codable, CaseIterable, Sendable {
    /// A reply drafted to be spoken as-is.
    case draftedResponse
    /// Bullet points the user turns into their own words.
    case supportingPoints
}

nonisolated enum CopilotInsightState: String, Codable, Sendable {
    case pending
    case streaming
    case complete
    case failed
    case cancelled
}

/// One card in the copilot stream.
///
/// Anchored to media time rather than to a segment ID on purpose: the offline
/// pipeline replaces provisional segments after Stop, and an insight must
/// survive that replacement (AD-002).
nonisolated struct CopilotInsight: Codable, Identifiable, Equatable, Sendable {
    var id: CopilotInsightID
    /// Media time of the speech that triggered this insight.
    var anchor: MeetingMediaTime
    var origin: CopilotInsightOrigin
    var format: CopilotInsightFormat
    /// Profile that generated it. Kept even after the user switches profiles, so
    /// earlier cards stay attributable (FR-010).
    var profileID: CopilotProfileID
    /// Short description of the situation the copilot detected.
    var situation: String
    /// What the other party said, quoted back for context.
    var quotedContext: String
    var body: String
    var state: CopilotInsightState
    /// User-facing failure text. Never a raw provider error.
    var errorMessage: String?
    var createdAt: Date

    init(
        id: CopilotInsightID = UUID(),
        anchor: MeetingMediaTime,
        origin: CopilotInsightOrigin,
        format: CopilotInsightFormat,
        profileID: CopilotProfileID,
        situation: String = "",
        quotedContext: String = "",
        body: String = "",
        state: CopilotInsightState = .pending,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.anchor = anchor
        self.origin = origin
        self.format = format
        self.profileID = profileID
        self.situation = situation
        self.quotedContext = quotedContext
        self.body = body
        self.state = state
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}

// MARK: - Chat

nonisolated struct CopilotChatMessage: Codable, Identifiable, Equatable, Sendable {
    nonisolated enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    var id: CopilotChatMessageID
    var role: Role
    var content: String
    /// Media time the question was asked at, so chat interleaves correctly with
    /// insights in the stream.
    var anchor: MeetingMediaTime?
    var errorMessage: String?
    var createdAt: Date

    init(
        id: CopilotChatMessageID = UUID(),
        role: Role,
        content: String,
        anchor: MeetingMediaTime? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.anchor = anchor
        self.errorMessage = errorMessage
        self.createdAt = createdAt
    }
}

// MARK: - Note

nonisolated enum CopilotNoteKind: String, Codable, CaseIterable, Sendable {
    case decision
    case actionItem
    case openQuestion
}

nonisolated struct CopilotNote: Codable, Identifiable, Equatable, Sendable {
    var id: CopilotNoteID
    var kind: CopilotNoteKind
    var text: String
    /// Where in the meeting this came from.
    var anchor: MeetingMediaTime
    var createdAt: Date

    init(
        id: CopilotNoteID = UUID(),
        kind: CopilotNoteKind,
        text: String,
        anchor: MeetingMediaTime,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.anchor = anchor
        self.createdAt = createdAt
    }
}

// MARK: - Briefing

/// Which transcript a briefing was generated from.
///
/// A briefing built before the offline pipeline finishes is preliminary and must
/// say so (FR-022).
nonisolated enum CopilotBriefingBasis: String, Codable, Sendable {
    case provisionalTranscript
    case finalTranscript
}

nonisolated struct CopilotBriefing: Codable, Identifiable, Equatable, Sendable {
    var id: CopilotBriefingID
    var profileID: CopilotProfileID
    /// Profile name at generation time, so the briefing stays readable after the
    /// profile is renamed or deleted.
    var profileName: String
    var body: String
    var basis: CopilotBriefingBasis
    var generatedAt: Date

    init(
        id: CopilotBriefingID = UUID(),
        profileID: CopilotProfileID,
        profileName: String,
        body: String,
        basis: CopilotBriefingBasis,
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.profileID = profileID
        self.profileName = profileName
        self.body = body
        self.basis = basis
        self.generatedAt = generatedAt
    }
}

// MARK: - Session Artifacts

nonisolated enum CopilotArtifactsValidationError: Error, Equatable {
    case unsupportedSchema(Int)
    case emptyProfileID
}

/// Everything the copilot produced for one meeting, persisted alongside the
/// session.
///
/// Deleting a meeting's audio must not remove these (FR-020); deleting the
/// meeting itself removes them with it (FR-021).
nonisolated struct CopilotSessionArtifacts: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var sessionID: MeetingSessionID
    /// Provider used for this session, recorded for auditability.
    var providerChoice: CopilotProviderChoice
    /// Profile selected when the session started. Later cards carry their own
    /// `profileID`, which may differ.
    var initialProfileID: CopilotProfileID?
    var insights: [CopilotInsight]
    var chatMessages: [CopilotChatMessage]
    var notes: [CopilotNote]
    var briefings: [CopilotBriefing]
    var updatedAt: Date

    init(
        sessionID: MeetingSessionID,
        providerChoice: CopilotProviderChoice = .local,
        initialProfileID: CopilotProfileID? = nil,
        insights: [CopilotInsight] = [],
        chatMessages: [CopilotChatMessage] = [],
        notes: [CopilotNote] = [],
        briefings: [CopilotBriefing] = [],
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.sessionID = sessionID
        self.providerChoice = providerChoice
        self.initialProfileID = initialProfileID
        self.insights = insights
        self.chatMessages = chatMessages
        self.notes = notes
        self.briefings = briefings
        self.updatedAt = updatedAt
    }

    var isEmpty: Bool {
        self.insights.isEmpty
            && self.chatMessages.isEmpty
            && self.notes.isEmpty
            && self.briefings.isEmpty
    }

    /// Mirrors `MeetingSession.validateForPersistence()`: refuse to write
    /// anything a future build wrote and this one cannot represent.
    func validateForPersistence() throws {
        guard self.schemaVersion > 0, self.schemaVersion <= Self.currentSchemaVersion else {
            throw CopilotArtifactsValidationError.unsupportedSchema(self.schemaVersion)
        }
        if let initialProfileID = self.initialProfileID, initialProfileID.isEmpty {
            throw CopilotArtifactsValidationError.emptyProfileID
        }
    }
}
