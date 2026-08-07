import SwiftUI

/// The copilot surface that accompanies the transcript.
///
/// Position (above or below) and collapsed state persist across sessions
/// (`FR-005`, `FR-006`); collapsing never affects the recording, which belongs
/// to the coordinator, not to this view.
struct CopilotPanelView: View {
    @ObservedObject var copilot: MeetingCopilotService
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var profileStore = MeetingCopilotProfileStore.shared

    @Environment(\.theme) private var theme

    /// Live height while a drag is in progress; committed to settings on
    /// release so the choice survives the session.
    @State private var dragOffset: CGFloat = 0

    /// Bounds keep both surfaces usable: the copilot never collapses to a
    /// sliver, and the transcript never disappears behind it.
    private static let minimumHeight: CGFloat = 160
    private static let maximumHeight: CGFloat = 900

    private var expandedHeight: CGFloat {
        min(
            Self.maximumHeight,
            max(Self.minimumHeight, self.settings.copilotPanelHeight - self.dragOffset)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if !self.settings.isCopilotPanelCollapsed {
                self.resizeHandle
            }

            self.header

            if !self.settings.isCopilotPanelCollapsed {
                Divider()
                if let reason = copilot.unavailableReason {
                    self.unavailableState(reason)
                        .frame(height: self.expandedHeight)
                } else {
                    CopilotStreamView(
                        insights: self.copilot.insights,
                        chatMessages: self.copilot.chatMessages
                    )
                    .frame(height: self.expandedHeight)
                }
            }
        }
        .background(self.theme.palette.sidebarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Meeting copilot")
    }

    /// A copilot that cannot run says why. An empty panel would look like a
    /// feature that is simply broken.
    private func unavailableState(_ reason: String) -> some View {
        VStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(self.theme.typography.titleIcon)
                .foregroundStyle(self.theme.palette.warning)
            Text("Copilot is not running")
                .font(self.theme.typography.bodySmallStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            Text(reason)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text("Recording and transcription are unaffected.")
                .font(self.theme.typography.tiny)
                .foregroundStyle(self.theme.palette.tertiaryText)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(self.theme.metrics.spacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Copilot is not running. \(reason). Recording and transcription are unaffected.")
    }

    // MARK: - Resize

    /// Drag target for resizing the panel.
    ///
    /// Deliberately taller than it looks: a 1px divider is a frustrating hit
    /// target, so the handle is 8pt with a visible line inside it.
    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .frame(height: 8)
                .contentShape(Rectangle())
            Divider()
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    self.dragOffset = value.translation.height
                }
                .onEnded { _ in
                    self.settings.copilotPanelHeight = self.expandedHeight
                    self.dragOffset = 0
                }
        )
        .onHover { hovering in
            if hovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Resize copilot panel")
        .accessibilityValue("\(Int(self.expandedHeight)) points tall")
        // Keyboard-reachable alternative to the drag (`A11Y-001`).
        .accessibilityAdjustableAction { direction in
            let step: CGFloat = 40
            switch direction {
            case .increment:
                self.settings.copilotPanelHeight = min(Self.maximumHeight, self.expandedHeight + step)
            case .decrement:
                self.settings.copilotPanelHeight = max(Self.minimumHeight, self.expandedHeight - step)
            @unknown default:
                break
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Button {
                self.settings.isCopilotPanelCollapsed.toggle()
            } label: {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    Image(systemName: self.settings.isCopilotPanelCollapsed ? "chevron.right" : "chevron.down")
                        .font(self.theme.typography.tiny)
                    Text("Copilot")
                        .font(self.theme.typography.bodySmallStrong)
                }
                .foregroundStyle(self.theme.palette.primaryText)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(self.settings.isCopilotPanelCollapsed ? "Expand copilot" : "Collapse copilot")

            CopilotProfilePicker(
                profiles: self.profileStore.profiles,
                selected: self.copilot.activeProfile,
                onSelect: { self.copilot.selectProfile($0) }
            )

            if self.copilot.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Copilot is working")
            }

            Spacer(minLength: 0)

            self.statusChips

            Menu {
                Picker("Panel position", selection: self.$settings.copilotPanelPlacement) {
                    ForEach(SettingsStore.CopilotPanelPlacement.allCases) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
                Picker("Suggestions", selection: self.$settings.copilotInsightTrigger) {
                    ForEach(SettingsStore.CopilotInsightTrigger.allCases) { trigger in
                        Text(trigger.displayName).tag(trigger)
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(self.theme.typography.caption)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Copilot options")
        }
        .padding(.horizontal, self.theme.metrics.spacing.lg)
        .padding(.vertical, self.theme.metrics.spacing.sm)
    }

    @ViewBuilder
    private var statusChips: some View {
        // Cloud is opt-in, and while it is on the user must be able to see where
        // their meeting audio is going at all times (`FR-027`).
        if self.settings.copilotProviderChoice == .cloud {
            Label("Cloud", systemImage: "cloud")
                .font(self.theme.typography.badge)
                .foregroundStyle(self.theme.palette.warning)
                .padding(.horizontal, self.theme.metrics.spacing.sm)
                .padding(.vertical, 2)
                .background(self.theme.palette.warning.opacity(0.12), in: Capsule())
                .help("Meeting transcript is being sent to your configured cloud provider.")
                .accessibilityLabel("Using cloud provider. Meeting transcript leaves this Mac.")
        } else {
            Label("On device", systemImage: "lock")
                .font(self.theme.typography.badge)
                .foregroundStyle(self.theme.palette.secondaryText)
                .padding(.horizontal, self.theme.metrics.spacing.sm)
                .padding(.vertical, 2)
                .background(self.theme.palette.contentBackground, in: Capsule())
                .help("Insights are generated locally. Nothing leaves this Mac.")
                .accessibilityLabel("Running on device. Nothing leaves this Mac.")
        }

        if self.copilot.droppedAudioChunks > 0 {
            Label("Degraded", systemImage: "waveform.badge.exclamationmark")
                .font(self.theme.typography.badge)
                .foregroundStyle(self.theme.palette.warning)
                .help("Some live audio was dropped, so the copilot may have missed part of the conversation. The recording itself is unaffected.")
                .accessibilityLabel("Live transcription degraded. The recording is unaffected.")
        }
    }
}
