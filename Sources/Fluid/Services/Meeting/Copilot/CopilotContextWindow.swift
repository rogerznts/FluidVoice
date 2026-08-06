import Foundation

/// The slice of meeting the copilot reasons over.
///
/// A meeting has no bounded length, but a prompt does. This keeps a sliding
/// window of recent speech plus a rolling summary of what fell out of it, so
/// cost and latency stay flat no matter how long the meeting runs (`FR-011`,
/// R-04).
nonisolated struct CopilotContextWindow: Sendable {
    /// One attributed line of speech.
    nonisolated struct Entry: Equatable, Sendable {
        var speaker: String
        var text: String
        var time: MeetingMediaTime
        /// `true` when this came from the local user's microphone, which lets
        /// prompts distinguish "what they said" from "what I said".
        var isLocalUser: Bool
    }

    /// Character budget for the verbatim window.
    ///
    /// Characters rather than tokens on purpose: tokenisation differs per model
    /// and the exactness buys nothing here. Roughly 4 characters per token, so
    /// this lands near 2k tokens of transcript.
    static let defaultCharacterBudget = 8000

    private(set) var entries: [Entry] = []
    /// Condensed account of what has already scrolled out of the window.
    private(set) var rollingSummary: String = ""

    let characterBudget: Int

    init(characterBudget: Int = Self.defaultCharacterBudget) {
        self.characterBudget = max(500, characterBudget)
    }

    var isEmpty: Bool {
        self.entries.isEmpty && self.rollingSummary.isEmpty
    }

    /// Text that has aged out of the window since the last summary update, if
    /// any. The engine turns this into prose and hands it back via
    /// `setRollingSummary`.
    private(set) var evictedSinceLastSummary: [Entry] = []

    // MARK: - Mutation

    mutating func append(_ entry: Entry) {
        self.entries.append(entry)
        self.trimToBudget()
    }

    mutating func append(
        speaker: String,
        text: String,
        time: MeetingMediaTime,
        isLocalUser: Bool = false
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.append(Entry(speaker: speaker, text: trimmed, time: time, isLocalUser: isLocalUser))
    }

    mutating func setRollingSummary(_ summary: String) {
        self.rollingSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.evictedSinceLastSummary.removeAll()
    }

    mutating func reset() {
        self.entries.removeAll()
        self.evictedSinceLastSummary.removeAll()
        self.rollingSummary = ""
    }

    /// Drops the oldest entries until the window fits its budget.
    ///
    /// Oldest-first because the copilot acts on the present: the tail of the
    /// conversation is what a suggestion has to answer.
    private mutating func trimToBudget() {
        var total = self.entries.reduce(0) { $0 + $1.text.count }
        while total > self.characterBudget, self.entries.count > 1 {
            let evicted = self.entries.removeFirst()
            total -= evicted.text.count
            self.evictedSinceLastSummary.append(evicted)
        }
    }

    // MARK: - Rendering

    /// The window as prompt-ready text, newest last.
    func transcriptText() -> String {
        self.entries
            .map { "\($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    /// The most recent entry — what a suggestion is usually answering.
    var latestEntry: Entry? {
        self.entries.last
    }

    /// Everything the model should see: the summary of what came before, then
    /// the verbatim window.
    func promptContext() -> String {
        var parts: [String] = []
        if !self.rollingSummary.isEmpty {
            parts.append("Earlier in the meeting:\n\(self.rollingSummary)")
        }
        let transcript = self.transcriptText()
        if !transcript.isEmpty {
            parts.append("Recent conversation:\n\(transcript)")
        }
        return parts.joined(separator: "\n\n")
    }
}
