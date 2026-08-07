import SwiftUI

/// Picks the profile that shapes the copilot's behaviour.
///
/// Switching mid-meeting affects only what comes next — cards already on screen
/// keep the profile that produced them (`FR-010`).
struct CopilotProfilePicker: View {
    let profiles: [MeetingCopilotProfile]
    let selected: MeetingCopilotProfile?
    let onSelect: (MeetingCopilotProfile) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Menu {
            ForEach(self.profiles) { profile in
                Button {
                    self.onSelect(profile)
                } label: {
                    Label(profile.name, systemImage: profile.symbolName)
                }
            }
        } label: {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: self.selected?.symbolName ?? "sparkles")
                    .font(self.theme.typography.caption)
                Text(self.selected?.name ?? "Choose a profile")
                    .font(self.theme.typography.captionStrong)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(self.theme.typography.tiny)
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }
            .foregroundStyle(self.theme.palette.primaryText)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Copilot profile")
        .accessibilityValue(self.selected?.name ?? "None selected")
        .help("The profile decides what the copilot pays attention to and how it answers.")
    }
}
