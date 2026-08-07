import SwiftUI

/// One entry in the copilot stream.
///
/// Layout follows the reference screens: what the copilot noticed, what the
/// other side said, then the suggestion itself. Everything comes from
/// `AppTheme` — no one-off chrome (`A11Y-009`).
struct CopilotInsightCard: View {
    let insight: CopilotInsight

    @Environment(\.theme) private var theme

    var body: some View {
        ThemedCard(style: .subtle) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                self.header

                if !self.insight.quotedContext.isEmpty {
                    self.quotedContext
                }

                self.bodyContent
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Rows in a lazy stack must settle their height on first measurement,
        // or the scroll oscillates as they materialise (see T030b).
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.accessibilityDescription)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            Image(systemName: self.originSymbol)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.accent)
                .accessibilityHidden(true)

            Text(self.insight.situation)
                .font(self.theme.typography.captionStrong)
                .foregroundStyle(self.theme.palette.secondaryText)

            Spacer(minLength: 0)

            // State is spelled out, never signalled by colour alone
            // (`A11Y-004`).
            if let stateLabel {
                Text(stateLabel)
                    .font(self.theme.typography.tiny)
                    .foregroundStyle(self.stateColor)
            }
        }
    }

    private var quotedContext: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text("They said")
                .font(self.theme.typography.tinyStrong)
                .foregroundStyle(self.theme.palette.tertiaryText)
                .textCase(.uppercase)

            Text(self.insight.quotedContext)
                .font(self.theme.typography.bodySmall)
                .italic()
                .foregroundStyle(self.theme.palette.secondaryText)
                .textSelection(.enabled)
                .lineLimit(4)
                .truncationMode(.head)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch self.insight.state {
        case .pending, .streaming:
            HStack(spacing: self.theme.metrics.spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Thinking…")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.tertiaryText)
            }

        case .failed:
            // A provider failure is reported here and nowhere else — capture
            // and transcription are untouched (`FR-012`).
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(self.theme.palette.warning)
                    .accessibilityHidden(true)
                Text(self.insight.errorMessage ?? "The copilot request failed.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }

        case .cancelled:
            Text("Superseded by a newer request.")
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.tertiaryText)

        case .complete:
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                Text(self.formatHeading)
                    .font(self.theme.typography.tinyStrong)
                    .foregroundStyle(self.theme.palette.accent)
                    .textCase(.uppercase)

                Text(self.insight.body)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(self.theme.metrics.spacing.md)
            .background(
                RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                    .fill(self.theme.palette.contentBackground)
            )
        }
    }

    // MARK: - Presentation

    /// `DEC-COP-002` surfaced: the heading tells the user whether this is
    /// something to say or something to work from.
    private var formatHeading: String {
        switch self.insight.format {
        case .draftedResponse:
            return "Say this"
        case .supportingPoints:
            return "Reading"
        }
    }

    private var originSymbol: String {
        switch self.insight.origin {
        case .automatic: return "sparkles"
        case .actionClarify: return "questionmark.circle"
        case .actionRecap: return "list.bullet.rectangle"
        case .actionLookUp: return "book"
        }
    }

    private var stateLabel: String? {
        switch self.insight.state {
        case .failed: return "Failed"
        case .cancelled: return "Superseded"
        case .pending, .streaming, .complete: return nil
        }
    }

    private var stateColor: Color {
        switch self.insight.state {
        case .failed: return self.theme.palette.warning
        default: return self.theme.palette.tertiaryText
        }
    }

    private var accessibilityDescription: String {
        var parts = [self.insight.situation]
        if !self.insight.quotedContext.isEmpty {
            parts.append("They said: \(self.insight.quotedContext)")
        }
        switch self.insight.state {
        case .complete:
            parts.append("\(self.formatHeading): \(self.insight.body)")
        case .failed:
            parts.append(self.insight.errorMessage ?? "Request failed")
        case .pending, .streaming:
            parts.append("Thinking")
        case .cancelled:
            parts.append("Superseded")
        }
        return parts.joined(separator: ". ")
    }
}

// MARK: - Chat Bubble

/// A chat exchange, rendered in the same stream as insights so the
/// conversation reads chronologically (`FR-007`).
struct CopilotChatBubble: View {
    let message: CopilotChatMessage

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: self.message.role == .user ? .trailing : .leading, spacing: self.theme.metrics.spacing.xs) {
            Text(self.message.role == .user ? "You asked" : "Copilot")
                .font(self.theme.typography.tinyStrong)
                .foregroundStyle(self.theme.palette.tertiaryText)
                .textCase(.uppercase)

            if let errorMessage = message.errorMessage {
                Text(errorMessage)
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
            } else if self.message.content.isEmpty {
                ProgressView().controlSize(.small)
            } else {
                Text(self.message.content)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(
            maxWidth: .infinity,
            alignment: self.message.role == .user ? .trailing : .leading
        )
        .padding(self.theme.metrics.spacing.md)
        .background(
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(
                    self.message.role == .user
                        ? self.theme.palette.accent.opacity(0.12)
                        : self.theme.palette.contentBackground
                )
        )
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
