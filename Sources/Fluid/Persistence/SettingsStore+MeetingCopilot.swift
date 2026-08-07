import Combine
import Foundation

extension SettingsStore {
    // MARK: - Panel Placement

    /// Where the copilot panel sits relative to the transcript (`FR-005`).
    enum CopilotPanelPlacement: String, Codable, CaseIterable, Identifiable {
        case above
        case below

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .above:
                return "Above transcript"
            case .below:
                return "Below transcript"
            }
        }
    }

    /// Whether the engine fires insights on its own or waits to be asked
    /// (`FR-009`, premissa A-01).
    enum CopilotInsightTrigger: String, Codable, CaseIterable, Identifiable {
        case automatic
        case manual

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .automatic:
                return "Automatic"
            case .manual:
                return "On request only"
            }
        }
    }

    // MARK: - Preferences

    /// Master switch for the copilot. Off by default: recording a meeting must
    /// not start sending anything anywhere without the user asking.
    var isCopilotEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: MeetingCopilotKeys.enabled) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: MeetingCopilotKeys.enabled)
        }
    }

    /// Language used for meeting transcription and copilot prompts.
    /// Defaults to English, matching the inherited behaviour.
    var meetingLanguageCode: String {
        get { UserDefaults.standard.string(forKey: MeetingCopilotKeys.language) ?? "en" }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: MeetingCopilotKeys.language)
        }
    }

    /// Height of the expanded copilot panel, in points.
    var copilotPanelHeight: CGFloat {
        get {
            let stored = UserDefaults.standard.double(forKey: MeetingCopilotKeys.panelHeight)
            return stored > 0 ? CGFloat(stored) : 320
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(Double(newValue), forKey: MeetingCopilotKeys.panelHeight)
        }
    }

    var copilotPanelPlacement: CopilotPanelPlacement {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: MeetingCopilotKeys.panelPlacement),
                  let placement = CopilotPanelPlacement(rawValue: rawValue)
            else {
                return .below
            }
            return placement
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: MeetingCopilotKeys.panelPlacement)
        }
    }

    var isCopilotPanelCollapsed: Bool {
        get { UserDefaults.standard.bool(forKey: MeetingCopilotKeys.panelCollapsed) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: MeetingCopilotKeys.panelCollapsed)
        }
    }

    var copilotInsightTrigger: CopilotInsightTrigger {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: MeetingCopilotKeys.insightTrigger),
                  let trigger = CopilotInsightTrigger(rawValue: rawValue)
            else {
                return .automatic
            }
            return trigger
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: MeetingCopilotKeys.insightTrigger)
        }
    }

    var defaultCopilotProfileID: String? {
        get { UserDefaults.standard.string(forKey: MeetingCopilotKeys.defaultProfileID) }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: MeetingCopilotKeys.defaultProfileID)
        }
    }

    /// Provider for copilot inference.
    ///
    /// Defaults to `.local`: no meeting speech leaves the Mac until the user
    /// says so (`FR-025`). Turning this to `.cloud` is the opt-in required by
    /// `FR-026`, and the UI must warn before it takes effect.
    var copilotProviderChoice: CopilotProviderChoice {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: MeetingCopilotKeys.providerChoice),
                  let choice = CopilotProviderChoice(rawValue: rawValue)
            else {
                return .local
            }
            return choice
        }
        set {
            objectWillChange.send()
            UserDefaults.standard.set(newValue.rawValue, forKey: MeetingCopilotKeys.providerChoice)
        }
    }
}

private enum MeetingCopilotKeys {
    static let enabled = "MeetingCopilotEnabled"
    static let language = "MeetingLanguageCode"
    static let panelPlacement = "MeetingCopilotPanelPlacement"
    static let panelHeight = "MeetingCopilotPanelHeight"
    static let panelCollapsed = "MeetingCopilotPanelCollapsed"
    static let insightTrigger = "MeetingCopilotInsightTrigger"
    static let defaultProfileID = "MeetingCopilotDefaultProfileID"
    static let providerChoice = "MeetingCopilotProviderChoice"
}
