import Foundation

// MARK: - Storage Protocol

/// Persistence for copilot artifacts, kept separate from `MeetingSessionStoring`
/// so the inherited protocol keeps its shape and future upstream merges do not
/// conflict on it.
nonisolated protocol MeetingCopilotArtifactStoring: Sendable {
    func loadArtifacts(sessionID: MeetingSessionID) async throws -> CopilotSessionArtifacts?
    func saveArtifacts(_ artifacts: CopilotSessionArtifacts) async throws
    func deleteArtifacts(sessionID: MeetingSessionID) async throws
}

// MARK: - Store Extension

extension MeetingSessionStore: MeetingCopilotArtifactStoring {
    /// Artifacts live beside the session manifest, in the session's own
    /// directory. Deleting the meeting therefore removes them with it
    /// (`FR-021`), while deleting only the audio leaves them untouched
    /// (`FR-020`).
    private static let artifactsFileName = "copilot.json"

    func loadArtifacts(sessionID: MeetingSessionID) throws -> CopilotSessionArtifacts? {
        let url = self.copilotArtifactsURL(for: sessionID)
        guard self.fileSystem.manager.fileExists(atPath: url.path) else { return nil }

        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let artifacts = try self.decoder.decode(CopilotSessionArtifacts.self, from: data)
        try artifacts.validateForPersistence()
        return artifacts
    }

    func saveArtifacts(_ artifacts: CopilotSessionArtifacts) throws {
        try artifacts.validateForPersistence()
        try self.prepareRootDirectory()

        let directory = self.sessionDirectoryURL(for: artifacts.sessionID)
        guard self.fileSystem.manager.fileExists(atPath: directory.path) else {
            throw MeetingCopilotArtifactStoreError.sessionDirectoryMissing
        }

        var stamped = artifacts
        stamped.updatedAt = Date()

        let data = try self.encoder.encode(stamped)
        try self.atomicPrivateWrite(data, to: self.copilotArtifactsURL(for: artifacts.sessionID))
    }

    func deleteArtifacts(sessionID: MeetingSessionID) throws {
        let url = self.copilotArtifactsURL(for: sessionID)
        guard self.fileSystem.manager.fileExists(atPath: url.path) else { return }
        try self.fileSystem.manager.removeItem(at: url)
    }

    private func copilotArtifactsURL(for id: MeetingSessionID) -> URL {
        self.sessionDirectoryURL(for: id).appendingPathComponent(Self.artifactsFileName)
    }
}

// MARK: - Session Deletion

extension MeetingSessionStore {
    /// Removes a meeting and everything it owns: manifest, audio tracks, and
    /// copilot artifacts (`FR-021`, `PRIV-015`).
    ///
    /// Deliberately not "delete audio only" — that is a separate action with
    /// different semantics, since a transcript stays useful after its audio is
    /// gone (`FR-020`).
    func deleteSession(id: MeetingSessionID) throws {
        let directory = self.sessionDirectoryURL(for: id)
        if self.fileSystem.manager.fileExists(atPath: directory.path) {
            try self.fileSystem.manager.removeItem(at: directory)
        }
        try self.removeFromIndex(id)
    }
}

// MARK: - Errors

nonisolated enum MeetingCopilotArtifactStoreError: Error, Equatable {
    /// Writing artifacts for a session that was never created would leave an
    /// orphan directory the session index knows nothing about.
    case sessionDirectoryMissing
}
