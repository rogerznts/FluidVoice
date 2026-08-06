@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Covers T007: artifacts round-trip, schema migration, and survival across a
/// store restart (`SC-006`).
final class CopilotArtifactPersistenceTests: XCTestCase {
    private var rootDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        self.rootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CopilotArtifactTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let rootDirectory, FileManager.default.fileExists(atPath: rootDirectory.path) {
            try FileManager.default.removeItem(at: rootDirectory)
        }
        self.rootDirectory = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func makeSession(languageCode: String = "en") -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(
            mode: .onlineCall,
            title: "Design sync",
            languageCode: languageCode,
            microphone: MeetingMicrophoneIdentity(
                captureDeviceID: "device-1",
                displayName: "MacBook Microphone"
            )
        )
        return MeetingSession(
            configuration: configuration,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
    }

    private func makeArtifacts(sessionID: MeetingSessionID) -> CopilotSessionArtifacts {
        let anchor = MeetingMediaTime(value: 6000, timescale: 600)
        return CopilotSessionArtifacts(
            sessionID: sessionID,
            providerChoice: .local,
            initialProfileID: "seed.sales.en",
            insights: [
                CopilotInsight(
                    anchor: anchor,
                    origin: .automatic,
                    format: .draftedResponse,
                    profileID: "seed.sales.en",
                    situation: "Prospect questions the timeline",
                    quotedContext: "Can you really ship by Q3?",
                    body: "We have two of the three milestones done.",
                    state: .complete
                ),
            ],
            chatMessages: [
                CopilotChatMessage(role: .user, content: "What did they say about pricing?", anchor: anchor),
                CopilotChatMessage(role: .assistant, content: "Pricing has not come up yet.", anchor: anchor),
            ],
            notes: [
                CopilotNote(kind: .actionItem, text: "Send the security questionnaire", anchor: anchor),
            ],
            briefings: [
                CopilotBriefing(
                    profileID: "seed.sales.en",
                    profileName: "Sales",
                    body: "## Summary\nStrong call.",
                    basis: .finalTranscript
                ),
            ]
        )
    }

    // MARK: - Round Trip

    func testArtifactsRoundTripThroughStore() async throws {
        let store = MeetingSessionStore(rootDirectory: self.rootDirectory)
        let session = self.makeSession()
        try await store.create(session)

        let artifacts = self.makeArtifacts(sessionID: session.id)
        try await store.saveArtifacts(artifacts)

        let loaded = try await store.loadArtifacts(sessionID: session.id)
        let unwrapped = try XCTUnwrap(loaded)

        XCTAssertEqual(unwrapped.sessionID, session.id)
        XCTAssertEqual(unwrapped.providerChoice, .local)
        XCTAssertEqual(unwrapped.initialProfileID, "seed.sales.en")
        XCTAssertEqual(unwrapped.insights.count, 1)
        XCTAssertEqual(unwrapped.insights.first?.format, .draftedResponse)
        XCTAssertEqual(unwrapped.insights.first?.body, "We have two of the three milestones done.")
        XCTAssertEqual(unwrapped.chatMessages.count, 2)
        XCTAssertEqual(unwrapped.notes.first?.kind, .actionItem)
        XCTAssertEqual(unwrapped.briefings.first?.basis, .finalTranscript)
    }

    /// `SC-006`: a fresh store instance over the same directory stands in for an
    /// app relaunch.
    func testArtifactsSurviveStoreRestart() async throws {
        let session = self.makeSession()
        let firstStore = MeetingSessionStore(rootDirectory: self.rootDirectory)
        try await firstStore.create(session)
        try await firstStore.saveArtifacts(self.makeArtifacts(sessionID: session.id))

        let secondStore = MeetingSessionStore(rootDirectory: self.rootDirectory)
        let loaded = try await secondStore.loadArtifacts(sessionID: session.id)

        XCTAssertEqual(loaded?.insights.count, 1)
        XCTAssertEqual(loaded?.notes.count, 1)
        XCTAssertEqual(loaded?.briefings.count, 1)
    }

    func testLoadingArtifactsForSessionWithoutThemReturnsNil() async throws {
        let store = MeetingSessionStore(rootDirectory: self.rootDirectory)
        let session = self.makeSession()
        try await store.create(session)

        let loaded = try await store.loadArtifacts(sessionID: session.id)

        XCTAssertNil(loaded)
    }

    func testSavingArtifactsWithoutSessionDirectoryFails() async throws {
        let store = MeetingSessionStore(rootDirectory: self.rootDirectory)
        let artifacts = self.makeArtifacts(sessionID: UUID())

        do {
            try await store.saveArtifacts(artifacts)
            XCTFail("Expected saveArtifacts to reject a session that was never created")
        } catch let error as MeetingCopilotArtifactStoreError {
            XCTAssertEqual(error, .sessionDirectoryMissing)
        }
    }

    // MARK: - Deletion

    /// `FR-020`: deleting audio must not take the copilot artifacts with it.
    func testDeletingArtifactsLeavesSessionIntact() async throws {
        let store = MeetingSessionStore(rootDirectory: self.rootDirectory)
        let session = self.makeSession()
        try await store.create(session)
        try await store.saveArtifacts(self.makeArtifacts(sessionID: session.id))

        try await store.deleteArtifacts(sessionID: session.id)

        let loadedArtifacts = try await store.loadArtifacts(sessionID: session.id)
        let loadedSession = try await store.load(id: session.id)
        XCTAssertNil(loadedArtifacts)
        XCTAssertNotNil(loadedSession)
    }

    func testDeletingAbsentArtifactsIsNotAnError() async throws {
        let store = MeetingSessionStore(rootDirectory: self.rootDirectory)
        let session = self.makeSession()
        try await store.create(session)

        try await store.deleteArtifacts(sessionID: session.id)
    }

    // MARK: - Validation

    func testArtifactsFromNewerSchemaAreRejected() throws {
        var artifacts = self.makeArtifacts(sessionID: UUID())
        artifacts.schemaVersion = CopilotSessionArtifacts.currentSchemaVersion + 1

        XCTAssertThrowsError(try artifacts.validateForPersistence()) { error in
            XCTAssertEqual(
                error as? CopilotArtifactsValidationError,
                .unsupportedSchema(CopilotSessionArtifacts.currentSchemaVersion + 1)
            )
        }
    }

    func testEmptyArtifactsReportEmpty() {
        let artifacts = CopilotSessionArtifacts(sessionID: UUID())

        XCTAssertTrue(artifacts.isEmpty)
    }

    // MARK: - Session Schema Migration (T005)

    /// A v1 manifest has neither copilot field. It must decode with the
    /// inherited defaults instead of failing.
    func testV1SessionManifestDecodesWithCopilotDefaults() throws {
        let session = self.makeSession()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(session)

        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        json["schemaVersion"] = 1
        json.removeValue(forKey: "transcriptMode")
        json.removeValue(forKey: "copilotProviderChoice")

        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let migrated = try decoder.decode(MeetingSession.self, from: legacyData)

        XCTAssertEqual(migrated.transcriptMode, .offlineAfterStop)
        XCTAssertEqual(migrated.copilotProviderChoice, .local)
        XCTAssertEqual(migrated.schemaVersion, MeetingSession.currentSchemaVersion)
        XCTAssertEqual(migrated.id, session.id)
        XCTAssertEqual(migrated.title, session.title)
    }

    func testLiveTranscriptModeSurvivesRoundTrip() async throws {
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom,
            title: "Standup",
            languageCode: "pt",
            microphone: MeetingMicrophoneIdentity(captureDeviceID: "device-2", displayName: "USB Mic")
        )
        let session = MeetingSession(
            configuration: configuration,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            transcriptMode: .live,
            copilotProviderChoice: .cloud
        )

        let store = MeetingSessionStore(rootDirectory: self.rootDirectory)
        try await store.create(session)
        let loaded = try await store.load(id: session.id)

        XCTAssertEqual(loaded?.transcriptMode, .live)
        XCTAssertEqual(loaded?.copilotProviderChoice, .cloud)
    }

    /// `DEC-COP-001` revokes upstream `DEC-001`: Portuguese must persist.
    func testPortugueseSessionPassesValidation() throws {
        let session = self.makeSession(languageCode: "pt")

        XCTAssertNoThrow(try session.validateForPersistence())
    }

    func testUnsupportedLanguageStillRejected() throws {
        let session = self.makeSession(languageCode: "de")

        XCTAssertThrowsError(try session.validateForPersistence())
    }
}
