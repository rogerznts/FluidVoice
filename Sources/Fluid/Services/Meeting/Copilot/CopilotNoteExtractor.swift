import Foundation

/// Parses the model's note output into typed notes.
///
/// A separate, pure type because the parsing is where this can silently go
/// wrong: a model that drifts from the requested format would otherwise produce
/// notes that look fine and say nothing. Here it is testable line by line.
nonisolated enum CopilotNoteExtractor {
    /// Sentinel the prompt asks for when a stretch yielded nothing. Treated as
    /// an explicit empty result rather than parsed as a note.
    static let emptyMarkers: Set<String> = ["EMPTY", "VAZIO"]

    /// Prefixes accepted for each note kind, in both prompt languages.
    private static let prefixes: [(kind: CopilotNoteKind, tokens: [String])] = [
        (.decision, ["DECISION:", "DECISAO:", "DECISÃO:"]),
        (.actionItem, ["ACTION:", "ACTION ITEM:", "PENDENCIA:", "PENDÊNCIA:"]),
        (.openQuestion, ["QUESTION:", "PERGUNTA:"]),
    ]

    static func parse(_ response: String, anchor: MeetingMediaTime) -> [CopilotNote] {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !Self.emptyMarkers.contains(trimmed.uppercased())
        else { return [] }

        return trimmed
            .split(separator: "\n")
            .compactMap { Self.parseLine(String($0), anchor: anchor) }
    }

    private static func parseLine(_ line: String, anchor: MeetingMediaTime) -> CopilotNote? {
        // Models like to bullet things even when not asked.
        var cleaned = line.trimmingCharacters(in: .whitespaces)
        for bullet in ["- ", "* ", "• "] where cleaned.hasPrefix(bullet) {
            cleaned = String(cleaned.dropFirst(bullet.count))
        }

        let upper = cleaned.uppercased()
        for entry in Self.prefixes {
            guard let token = entry.tokens.first(where: { upper.hasPrefix($0) }) else { continue }
            let text = String(cleaned.dropFirst(token.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return CopilotNote(kind: entry.kind, text: text, anchor: anchor)
        }

        // A line with no recognised prefix is prose, not a note. Dropping it is
        // better than filing it under a guessed type.
        return nil
    }

    /// Merges newly extracted notes into the existing set, skipping ones that
    /// repeat what is already recorded.
    ///
    /// Notes are extracted repeatedly over a meeting and the same decision will
    /// surface more than once; without this the list becomes a transcript of
    /// itself.
    static func merge(_ new: [CopilotNote], into existing: [CopilotNote]) -> [CopilotNote] {
        var result = existing
        for note in new where !result.contains(where: { Self.isDuplicate($0, note) }) {
            result.append(note)
        }
        return result
    }

    private static func isDuplicate(_ lhs: CopilotNote, _ rhs: CopilotNote) -> Bool {
        lhs.kind == rhs.kind && Self.normalise(lhs.text) == Self.normalise(rhs.text)
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: "")
    }
}
