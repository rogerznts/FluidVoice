@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T002 and T003: the profile model, the shipped seeds in both
/// languages, and the mutations the picker relies on.
final class MeetingCopilotProfileStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.suiteName = "MeetingCopilotProfileStoreTests-\(UUID().uuidString)"
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.suiteName))
    }

    override func tearDownWithError() throws {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        self.defaults = nil
        self.suiteName = nil
        try super.tearDownWithError()
    }

    // MARK: - Seeding

    func testSeedingInstallsFiveProfilesPerLanguage() {
        let store = MeetingCopilotProfileStore(defaults: self.defaults)

        store.seedIfNeeded(for: .portuguese)

        XCTAssertEqual(store.profiles.count, 5)
        XCTAssertTrue(store.profiles.allSatisfy { !$0.isCustomized })
    }

    func testSeedingIsIdempotent() {
        let store = MeetingCopilotProfileStore(defaults: self.defaults)

        store.seedIfNeeded(for: .english)
        store.seedIfNeeded(for: .english)
        store.seedIfNeeded(for: .english)

        XCTAssertEqual(store.profiles.count, 5)
    }

    func testBothLanguagesCoexist() {
        let store = MeetingCopilotProfileStore(defaults: self.defaults)

        store.seedIfNeeded(for: .portuguese)
        store.seedIfNeeded(for: .english)

        XCTAssertEqual(store.profiles.count, 10)
    }

    /// Re-seeding after a deliberate delete would resurrect the profile, which
    /// reads as the app overriding the user.
    func testSeedingDoesNotResurrectDeletedProfile() {
        let store = MeetingCopilotProfileStore(defaults: self.defaults)
        store.seedIfNeeded(for: .english)
        let victim = try? XCTUnwrap(store.profiles.first)
        guard let victim else { return XCTFail("expected a seeded profile") }

        store.delete(id: victim.id)
        store.seedIfNeeded(for: .english)

        XCTAssertEqual(store.profiles.count, 4)
        XCTAssertNil(store.profile(id: victim.id))
    }

    func testEverySeedCarriesBothPrompts() {
        for language in CopilotSeedLanguage.allCases {
            for profile in MeetingCopilotProfileStore.seeds(for: language) {
                XCTAssertFalse(
                    profile.insightPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(profile.id) has an empty insight prompt"
                )
                XCTAssertFalse(
                    profile.briefingPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(profile.id) has an empty briefing prompt"
                )
            }
        }
    }

    /// `DEC-COP-002`: the format is a per-profile decision, so both values must
    /// actually appear among the seeds.
    func testSeedsUseBothInsightFormats() {
        let formats = Set(MeetingCopilotProfileStore.seeds(for: .portuguese).map(\.insightFormat))

        XCTAssertEqual(formats, [.draftedResponse, .supportingPoints])
    }

    func testSeedIDsAreUniqueAcrossLanguages() {
        let allIDs = CopilotSeedLanguage.allCases
            .flatMap { MeetingCopilotProfileStore.seeds(for: $0) }
            .map(\.id)

        XCTAssertEqual(Set(allIDs).count, allIDs.count)
    }

    // MARK: - Language Resolution

    func testLanguageResolutionMapsSessionCodes() {
        XCTAssertEqual(CopilotSeedLanguage.resolve(from: "pt"), .portuguese)
        XCTAssertEqual(CopilotSeedLanguage.resolve(from: "pt-BR"), .portuguese)
        XCTAssertEqual(CopilotSeedLanguage.resolve(from: "pt_BR"), .portuguese)
        XCTAssertEqual(CopilotSeedLanguage.resolve(from: "PT-br"), .portuguese)
        XCTAssertEqual(CopilotSeedLanguage.resolve(from: "en"), .english)
        XCTAssertEqual(CopilotSeedLanguage.resolve(from: "en-US"), .english)
    }

    /// Anything not shipped falls back rather than failing: an unexpected code
    /// should not leave the copilot without a prompt.
    func testUnknownLanguageFallsBackToEnglish() {
        XCTAssertEqual(CopilotSeedLanguage.resolve(from: "de"), .english)
        XCTAssertEqual(CopilotSeedLanguage.resolve(from: ""), .english)
    }

    // MARK: - Mutations

    func testUpdateMarksProfileCustomized() {
        let store = MeetingCopilotProfileStore(defaults: self.defaults)
        store.seedIfNeeded(for: .english)
        guard var profile = store.profiles.first else { return XCTFail("expected a seeded profile") }

        profile.insightPrompt = "Rewritten by the user"
        store.update(profile)

        let reloaded = store.profile(id: profile.id)
        XCTAssertEqual(reloaded?.insightPrompt, "Rewritten by the user")
        XCTAssertEqual(reloaded?.isCustomized, true)
    }

    func testDuplicateCreatesIndependentCopy() {
        let store = MeetingCopilotProfileStore(defaults: self.defaults)
        store.seedIfNeeded(for: .english)
        guard let source = store.profiles.first else { return XCTFail("expected a seeded profile") }

        let copy = store.duplicate(id: source.id)

        let unwrapped = try? XCTUnwrap(copy)
        XCTAssertNotNil(unwrapped)
        XCTAssertNotEqual(unwrapped?.id, source.id)
        XCTAssertEqual(unwrapped?.insightPrompt, source.insightPrompt)
        XCTAssertEqual(store.profiles.count, 6)
    }

    func testDeletingSelectedProfileMovesSelection() {
        let store = MeetingCopilotProfileStore(defaults: self.defaults)
        store.seedIfNeeded(for: .english)
        guard let selected = store.profiles.first else { return XCTFail("expected a seeded profile") }
        store.selectedProfileID = selected.id

        store.delete(id: selected.id)

        XCTAssertNotEqual(store.selectedProfileID, selected.id)
        XCTAssertNotNil(store.selectedProfileID)
    }

    func testProfilesPersistAcrossStoreInstances() {
        let first = MeetingCopilotProfileStore(defaults: self.defaults)
        first.seedIfNeeded(for: .portuguese)
        first.add(
            MeetingCopilotProfile(
                name: "Retro",
                insightPrompt: "prompt",
                briefingPrompt: "briefing",
                insightFormat: .supportingPoints
            )
        )

        let second = MeetingCopilotProfileStore(defaults: self.defaults)

        XCTAssertEqual(second.profiles.count, 6)
        XCTAssertTrue(second.profiles.contains { $0.name == "Retro" })
    }
}
