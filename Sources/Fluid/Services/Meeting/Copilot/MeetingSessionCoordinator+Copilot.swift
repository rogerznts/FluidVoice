import Foundation

extension MeetingSessionCoordinator {
    /// Brings the copilot up for a session that just started recording.
    ///
    /// Everything here is best-effort. A copilot that cannot start — no
    /// provider configured, no model on disk — leaves the meeting recording
    /// exactly as it would without this feature (`FR-002`, `FR-012`).
    func startCopilot(for session: MeetingSession) {
        guard session.transcriptMode == .live else { return }

        let language = CopilotSeedLanguage.resolve(from: session.languageCode)
        let choice = session.copilotProviderChoice
        let route = CopilotProviderRoute.resolve(choice: choice)

        guard route.isUsable else {
            DebugLogger.shared.log(
                "MeetingCopilot: no usable \(choice.rawValue) provider; running without copilot",
                level: .info,
                source: "MeetingCopilot"
            )
            return
        }

        let service = MeetingCopilotService(
            sessionID: session.id,
            language: language,
            providerChoice: choice,
            route: route
        )
        self.setCopilot(service)

        let tap = LiveTranscriptionTap(
            delegate: CopilotLiveTranscriptionBridge(coordinator: self),
            providerFactory: { @Sendable in
                // Same accessor file transcription uses, so the live path never
                // instantiates a second model (`PIPE-006`).
                await MainActor.run { AppServices.shared.asr.fileTranscriptionProvider }
            }
        )
        self.setLiveTranscriptionTap(tap)

        Task { [capture = self.captureController] in
            await capture.setLiveAudioSink(tap)
        }
        tap.start()
    }

    /// Tears the copilot down, flushing whatever it produced.
    func stopCopilot() async {
        self.liveTranscriptionTapValue?.stop()
        self.liveTranscriptionTapValue?.discardPending()
        self.setLiveTranscriptionTap(nil)

        await self.captureController.setLiveAudioSink(nil)

        if let copilot = self.copilot {
            await copilot.finish()
        }
        self.setCopilot(nil)
    }
}

// MARK: - Live Transcription Bridge

/// Carries live transcript output from the tap to the copilot.
///
/// A separate object rather than conforming the coordinator itself: the tap's
/// delegate is `nonisolated` and `Sendable`, while the coordinator is
/// `@MainActor`. This keeps the hop explicit instead of scattering it.
private final class CopilotLiveTranscriptionBridge: LiveTranscriptionTapDelegate, @unchecked Sendable {
    private weak var coordinator: MeetingSessionCoordinator?

    init(coordinator: MeetingSessionCoordinator) {
        self.coordinator = coordinator
    }

    func liveTranscription(
        didProduce text: String,
        from kind: MeetingAudioTrackKind,
        start: MeetingMediaTime,
        end: MeetingMediaTime
    ) async {
        await MainActor.run { [weak coordinator] in
            coordinator?.appendProvisionalSegment(text: text, kind: kind, start: start, end: end)
        }

        // Microphone speech is the local user in online-call mode; application
        // audio is everyone else. The copilot answers the other side.
        let isLocalUser = kind == .microphone
        let speaker = isLocalUser ? "You" : "Them"

        guard let copilot = await MainActor.run(body: { coordinator?.copilot }) else { return }
        await copilot.ingestTranscript(
            speaker: speaker,
            text: text,
            time: start,
            isLocalUser: isLocalUser
        )
    }

    func liveTranscriptionDidDropAudio(count: Int) async {
        guard let copilot = await MainActor.run(body: { coordinator?.copilot }) else { return }
        await copilot.noteDroppedAudio(count: count)
    }
}
