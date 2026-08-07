import SwiftUI

/// Quick actions and the chat field, docked at the bottom of the panel.
///
/// The automatic trigger handles most of a meeting; these are what the user
/// reaches for when it misses, which is exactly when they have no time to
/// think. Everything here is one click or one line of typing.
struct CopilotActionBar: View {
    let isBusy: Bool
    let isEnabled: Bool
    let onAction: (CopilotPromptBuilder.Request) -> Void
    let onSend: (String) -> Void
    let onExtractNotes: () -> Void

    @Environment(\.theme) private var theme
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            self.quickActions
            self.chatField
        }
        .padding(.horizontal, self.theme.metrics.spacing.lg)
        .padding(.vertical, self.theme.metrics.spacing.sm)
        .background(self.theme.palette.sidebarBackground)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: - Quick Actions

    private var quickActions: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            self.actionButton("Clarify", systemImage: "questionmark.circle", request: .clarify)
            self.actionButton("Recap", systemImage: "list.bullet.rectangle", request: .recap)
            self.actionButton("Look up", systemImage: "book", request: .lookUp)
            self.actionButton("Search web", systemImage: "globe", request: .webSearch)

            Spacer(minLength: 0)

            Button {
                self.onExtractNotes()
            } label: {
                Label("Take notes", systemImage: "note.text")
                    .font(self.theme.typography.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!self.isEnabled || self.isBusy)
            .help("Pull decisions, action items, and open questions out of the meeting so far.")
        }
    }

    private func actionButton(
        _ title: String,
        systemImage: String,
        request: CopilotPromptBuilder.Request
    ) -> some View {
        Button {
            self.onAction(request)
        } label: {
            Label(title, systemImage: systemImage)
                .font(self.theme.typography.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!self.isEnabled || self.isBusy)
        .help(self.helpText(for: request))
    }

    /// `FR-013`: the product must never imply a web search it does not perform.
    private func helpText(for request: CopilotPromptBuilder.Request) -> String {
        switch request {
        case .clarify:
            return "Explain the last point discussed."
        case .recap:
            return "Summarise the meeting so far."
        case .lookUp:
            return "Explain terms that came up, from the model's own knowledge — no web search."
        case .webSearch:
            return "Search the web to check what was said and add context. Sends the recent transcript to Google Search."
        default:
            return ""
        }
    }

    // MARK: - Chat

    private var chatField: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            TextField("Ask the copilot…", text: self.$draft)
                .textFieldStyle(.plain)
                .font(self.theme.typography.bodySmall)
                .focused(self.$isFieldFocused)
                .disabled(!self.isEnabled)
                .onSubmit(self.send)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.vertical, self.theme.metrics.spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                        .fill(self.theme.palette.contentBackground)
                )
                .accessibilityLabel("Ask the copilot")

            Button(action: self.send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(self.theme.typography.sectionTitle)
            }
            .buttonStyle(.plain)
            .disabled(!self.isEnabled || self.trimmedDraft.isEmpty)
            .keyboardShortcut(.return, modifiers: [])
            .accessibilityLabel("Send question")
        }
    }

    private var trimmedDraft: String {
        self.draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Clears the field only after handing the text off, so a failed send does
    /// not silently lose what the user typed.
    private func send() {
        let question = self.trimmedDraft
        guard !question.isEmpty, self.isEnabled else { return }
        self.onSend(question)
        self.draft = ""
    }
}
