import SwiftUI

/// Notes and briefings for a meeting.
///
/// Shown on the result canvas rather than in the live panel: both are things
/// you read after the conversation, not during it.
struct CopilotBriefingView: View {
    @ObservedObject var copilot: MeetingCopilotService
    @ObservedObject private var profileStore = MeetingCopilotProfileStore.shared

    @Environment(\.theme) private var theme
    @State private var briefingProfile: MeetingCopilotProfile?

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            if !self.copilot.notes.isEmpty {
                self.notesSection
            }
            self.briefingSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Notes

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Text("Notes")
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)

            ForEach(CopilotNoteKind.allCases, id: \.self) { kind in
                let notes = self.copilot.notes.filter { $0.kind == kind }
                if !notes.isEmpty {
                    self.noteGroup(kind: kind, notes: notes)
                }
            }
        }
    }

    private func noteGroup(kind: CopilotNoteKind, notes: [CopilotNote]) -> some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Label(Self.title(for: kind), systemImage: Self.symbol(for: kind))
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)

            ForEach(notes) { note in
                Text("• \(note.text)")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func title(for kind: CopilotNoteKind) -> String {
        switch kind {
        case .decision: return "Decisions"
        case .actionItem: return "Action items"
        case .openQuestion: return "Open questions"
        }
    }

    private static func symbol(for kind: CopilotNoteKind) -> String {
        switch kind {
        case .decision: return "checkmark.seal"
        case .actionItem: return "arrow.right.circle"
        case .openQuestion: return "questionmark.circle"
        }
    }

    // MARK: - Briefing

    private var briefingSection: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            HStack(spacing: self.theme.metrics.spacing.md) {
                Text("Briefing")
                    .font(self.theme.typography.sectionTitle)
                    .foregroundStyle(self.theme.palette.primaryText)

                Spacer(minLength: 0)

                CopilotProfilePicker(
                    profiles: self.profileStore.profiles,
                    selected: self.briefingProfile ?? self.copilot.activeProfile,
                    onSelect: { self.briefingProfile = $0 }
                )

                Button {
                    Task { await self.generate() }
                } label: {
                    Label("Generate", systemImage: "doc.text")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(self.copilot.isBusy || self.selectedProfile == nil)

                if self.copilot.isBusy {
                    ProgressView().controlSize(.small)
                }
            }

            if self.copilot.briefings.isEmpty {
                Text("Generate a briefing formatted by the profile you pick.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.tertiaryText)
            } else {
                // Newest first: the most recent generation is what the user
                // just asked for.
                ForEach(self.copilot.briefings.reversed()) { briefing in
                    self.briefingCard(briefing)
                }
            }
        }
    }

    private func briefingCard(_ briefing: CopilotBriefing) -> some View {
        ThemedCard(style: .subtle) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Text(briefing.profileName)
                        .font(self.theme.typography.captionStrong)
                        .foregroundStyle(self.theme.palette.accent)
                    Text(briefing.generatedAt.formatted(date: .omitted, time: .shortened))
                        .font(self.theme.typography.tiny)
                        .foregroundStyle(self.theme.palette.tertiaryText)

                    Spacer(minLength: 0)

                    // A briefing built before processing finished is a draft,
                    // and saying so is the difference between a summary and a
                    // misleading one (`FR-022`).
                    if briefing.basis == .provisionalTranscript {
                        Label("Preliminary", systemImage: "exclamationmark.triangle")
                            .font(self.theme.typography.badge)
                            .foregroundStyle(self.theme.palette.warning)
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(briefing.body, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .help("Copy briefing")
                    .accessibilityLabel("Copy briefing")
                }

                Text(briefing.body)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var selectedProfile: MeetingCopilotProfile? {
        self.briefingProfile ?? self.copilot.activeProfile ?? self.profileStore.profiles.first
    }

    private func generate() async {
        guard let profile = selectedProfile else { return }
        await self.copilot.generateBriefing(using: profile)
    }
}
