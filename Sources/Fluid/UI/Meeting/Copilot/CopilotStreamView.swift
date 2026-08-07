import SwiftUI

/// One chronological stream of everything the copilot produced: automatic
/// insights, quick-action answers, and chat (`FR-007`).
///
/// Virtualised, with rows that settle their height on first measurement — the
/// combination `PERF-004` and `FR-008` require, and the one T030b established
/// is needed to keep the scroll from oscillating.
struct CopilotStreamView: View {
    let insights: [CopilotInsight]
    let chatMessages: [CopilotChatMessage]

    @Environment(\.theme) private var theme

    /// Insights and chat merged by **when they appeared**, not by media time.
    ///
    /// Media time was the obvious choice and the wrong one: a manual action
    /// happens now but anchors to the media time of the last thing said, which
    /// can be earlier than cards already on screen — so pressing a button
    /// inserted its answer above them instead of at the end.
    private var entries: [Entry] {
        let insightEntries = self.insights.map {
            Entry(id: $0.id, sortKey: $0.createdAt, kind: .insight($0))
        }
        let chatEntries = self.chatMessages.map {
            Entry(id: $0.id, sortKey: $0.createdAt, kind: .chat($0))
        }
        return (insightEntries + chatEntries).sorted { lhs, rhs in
            lhs.sortKey == rhs.sortKey ? lhs.id.uuidString < rhs.id.uuidString : lhs.sortKey < rhs.sortKey
        }
    }

    var body: some View {
        if self.entries.isEmpty {
            self.emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        ForEach(self.entries) { entry in
                            switch entry.kind {
                            case let .insight(insight):
                                CopilotInsightCard(insight: insight).id(entry.id)
                            case let .chat(message):
                                CopilotChatBubble(message: message).id(entry.id)
                            }
                        }
                    }
                    .padding(self.theme.metrics.spacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: self.entries.count) { _, _ in
                    guard let lastID = entries.last?.id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "sparkles")
                .font(self.theme.typography.titleIcon)
                .foregroundStyle(self.theme.palette.tertiaryText)
            Text("The copilot is listening")
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.secondaryText)
            Text("Suggestions appear as the conversation develops.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.tertiaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(self.theme.metrics.spacing.lg)
    }

    // MARK: - Entry

    private struct Entry: Identifiable {
        enum Kind {
            case insight(CopilotInsight)
            case chat(CopilotChatMessage)
        }

        let id: UUID
        let sortKey: Date
        let kind: Kind
    }
}
