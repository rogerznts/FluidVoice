import Foundation

/// Serializes access to the shared ASR provider between the live tap and the
/// offline meeting pipeline.
///
/// Both paths would otherwise call into the same model instance concurrently,
/// which `PIPE-006` and `PIPE-015` forbid: the offline pass may load, unload, or
/// reconfigure the provider, and a concurrent live call could observe a
/// half-configured model or corrupt a partial result.
///
/// The asymmetry is deliberate. Offline work is authoritative and always runs;
/// live work is a convenience and **yields**. When the offline path holds or
/// wants the provider, live requests are refused outright rather than queued —
/// a live transcription that arrives late is worthless, so waiting for it only
/// grows a backlog (R-01, AD-001).
actor MeetingASRAccessArbiter {
    static let shared = MeetingASRAccessArbiter()

    private var offlineHolders = 0
    private var liveInFlight = false

    init() {}

    /// Runs an offline pass with exclusive access, waiting for any in-flight
    /// live call to finish first.
    func runOffline<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        self.offlineHolders += 1
        defer { self.offlineHolders -= 1 }

        while self.liveInFlight {
            await Task.yield()
        }

        return try await operation()
    }

    /// Runs a live pass, or returns `nil` when the provider belongs to the
    /// offline path or another live call is already running.
    ///
    /// A `nil` result is a normal outcome, not an error: the caller drops that
    /// window of audio and tries again with fresher audio.
    func runLiveIfAvailable<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T? {
        guard self.offlineHolders == 0, !self.liveInFlight else { return nil }

        self.liveInFlight = true
        defer { self.liveInFlight = false }

        return try await operation()
    }

    /// Whether the offline path currently owns the provider. Used by the UI to
    /// explain why live insight paused instead of appearing broken.
    var isOfflineActive: Bool {
        self.offlineHolders > 0
    }
}
