import Foundation

// MARK: - Provisional Segment Builder

/// Builds provisional transcript segments from live transcription output.
///
/// Provisional segments live in the same `transcriptSegments` array as final
/// ones (`LIVE-002`, AD-002): one array, one source of truth, distinguished by
/// `status` rather than by a parallel store.
nonisolated enum LiveTranscriptSegmentBuilder {
    static func makeSegment(
        text: String,
        trackID: MeetingAudioTrackID,
        start: MeetingMediaTime,
        end: MeetingMediaTime,
        id: MeetingTranscriptSegmentID = UUID()
    ) -> MeetingTranscriptSegment {
        MeetingTranscriptSegment(
            id: id,
            start: start,
            end: end,
            sourceTrackID: trackID,
            speakerID: nil,
            text: text,
            revision: 0,
            status: .provisional,
            overlap: .none,
            completeness: .complete
        )
    }
}

// MARK: - Reconciliation

/// Replaces provisional segments with the authoritative offline result once
/// processing finishes.
///
/// The rule that matters (`LIVE-007`, `LIVE-008`, R-03): **a user edit always
/// wins**. Someone who corrected a name or fixed a word during the meeting must
/// not watch that work vanish when the offline pass lands. A provisional segment
/// the user touched is promoted, not discarded.
nonisolated enum LiveTranscriptReconciler {
    /// A provisional segment counts as user-owned once its revision moves past
    /// the value the live tap writes.
    static func isUserEdited(_ segment: MeetingTranscriptSegment) -> Bool {
        segment.status == .provisional && segment.revision > 0
    }

    /// Merges final segments into a session that may hold provisional ones.
    ///
    /// - Provisional segments the user did not touch are dropped: the offline
    ///   pass covers the same audio, with speaker labels and better accuracy.
    /// - Provisional segments the user edited are promoted to `.final` and kept.
    /// - Segments already `.final` are replaced by their newer counterpart when
    ///   the offline pass produces one with the same ID.
    static func reconcile(
        existing: [MeetingTranscriptSegment],
        finalSegments: [MeetingTranscriptSegment]
    ) -> [MeetingTranscriptSegment] {
        let preserved = existing
            .filter { self.isUserEdited($0) }
            .map { segment -> MeetingTranscriptSegment in
                var promoted = segment
                promoted.status = .final
                return promoted
            }

        var merged: [MeetingTranscriptSegment] = []
        merged.reserveCapacity(finalSegments.count + preserved.count)

        // Final output first, then the user's own edits, so an edit that
        // overlaps a final segment is not silently deduplicated away.
        var seenIDs = Set<MeetingTranscriptSegmentID>()
        for segment in finalSegments where !seenIDs.contains(segment.id) {
            seenIDs.insert(segment.id)
            merged.append(segment)
        }
        for segment in preserved where !seenIDs.contains(segment.id) {
            seenIDs.insert(segment.id)
            merged.append(segment)
        }

        return merged.sorted { lhs, rhs in
            if lhs.start == rhs.start {
                return lhs.end < rhs.end
            }
            return lhs.start < rhs.start
        }
    }

    /// Reconciles a session in place and returns whether anything changed.
    @discardableResult
    static func reconcile(
        session: inout MeetingSession,
        finalSegments: [MeetingTranscriptSegment]
    ) -> Bool {
        let reconciled = self.reconcile(
            existing: session.transcriptSegments,
            finalSegments: finalSegments
        )
        guard reconciled != session.transcriptSegments else { return false }

        session.transcriptSegments = reconciled
        session.updatedAt = Date()
        return true
    }

    /// Drops every untouched provisional segment without waiting for offline
    /// output. Used when processing fails: stale provisional text presented as
    /// a result would misrepresent what the app actually knows.
    static func discardUntouchedProvisional(
        in segments: [MeetingTranscriptSegment]
    ) -> [MeetingTranscriptSegment] {
        segments.filter { $0.status == .final || self.isUserEdited($0) }
    }
}
