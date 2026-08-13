import Foundation

/// Turns the spool a crashed session left behind into a segment on the next launch.
///
/// A spool directory that still exists at launch means the session that owned it never
/// reached `stop()`. That is the definition of "unfinished" here: cleanup on a clean
/// shutdown is what makes the leftover meaningful, so no separate crash marker, signal
/// handler, or exception hook is needed — and none of those are reliable against
/// `SIGKILL` or a watchdog kill anyway.
///
/// A user swiping the app away also leaves a spool behind and is recovered the same way.
/// The two are indistinguishable on disk, and the window is worth having either way.
enum CrashRecovery {
    /// Spools kept for recovery, newest first. A crash loop generates one per launch;
    /// anything older than this is stale enough that nobody will look at it.
    static let maxRecoverableSessions = 2

    /// A spool that has already failed to recover this many times is discarded rather
    /// than retried. Without this, a frame set that reliably kills the encoder is
    /// re-encoded on every single launch and never goes away.
    static let maxRecoveryAttempts = 2

    struct Limits {
        var totalByteBudget: Int
        var maxSessions: Int = CrashRecovery.maxRecoverableSessions
    }

    /// One crashed session, reconstituted: the segment to upload plus the row that closes
    /// the session out.
    ///
    /// Both are handed back rather than sent from here, because recovery has no business
    /// knowing about the network — and the caller is the only thing that holds the
    /// endpoint and key.
    struct RecoveredSession {
        let sessionId: String
        let segment: PreparedSegment
        /// The `ended` row for the crashed session. Its `active` row was posted at that
        /// session's own start, so this is the only one missing.
        let endedRow: SessionMetaRow
        /// Timestamp of the last spooled frame — the best end time available, and the one
        /// `endedRow` must be stamped with rather than the moment of recovery.
        let endedAt: Date
    }

    /// Recover every unfinished session under `root`, emitting one segment each.
    ///
    /// Runs off the main thread. `activeSessionId` is the session that just started —
    /// its spool is live and must never be pruned or recovered.
    @discardableResult
    static func recoverPendingSessions(
        root: URL,
        activeSessionId: String?,
        limits: Limits,
        persistToDisk: Bool = false,
        onRecovered: (RecoveredSession) -> Void
    ) -> [RecoveredSession] {
        var pending = pendingSessions(root: root, activeSessionId: activeSessionId)
        pending = prune(pending, limits: limits)

        var recovered: [RecoveredSession] = []
        for session in pending {
            guard let result = recover(session, root: root, persistToDisk: persistToDisk) else { continue }
            recovered.append(result)
            onRecovered(result)
        }
        return recovered
    }

    /// Unfinished spools, newest first.
    static func pendingSessions(root: URL, activeSessionId: String?) -> [SpooledSession] {
        let spoolRoot = FrameSpool.spoolRoot(in: root)
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: spoolRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        return directories
            .filter { $0.lastPathComponent != activeSessionId }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(SpooledSession.read)
            .sorted { $0.manifest.startedAt > $1.manifest.startedAt }
    }

    /// Enforce the disk ceiling before any recovery work happens.
    ///
    /// This is the crash-loop guard: each launch of a crashing app leaves another spool,
    /// so the bound has to be applied to the set, not just within a session. Oldest go
    /// first, and deletion happens up front so a device that is already near its limit
    /// isn't asked to hold the spools *and* the MP4s recovery produces.
    static func prune(_ sessions: [SpooledSession], limits: Limits) -> [SpooledSession] {
        var kept: [SpooledSession] = []
        var total = 0

        for session in sessions {  // newest first
            let size = session.byteSize
            if kept.count < max(0, limits.maxSessions), total + size <= limits.totalByteBudget {
                kept.append(session)
                total += size
            } else {
                try? FileManager.default.removeItem(at: session.directory)
            }
        }
        return kept
    }

    /// Encode one spooled session into a segment and clean up after it.
    private static func recover(
        _ session: SpooledSession,
        root: URL,
        persistToDisk: Bool
    ) -> RecoveredSession? {
        var session = session

        // Record the attempt *before* doing the work. If encoding is what kills the
        // process, the incremented count is already durable, and the next launch counts
        // one closer to giving up instead of repeating the same crash.
        session.manifest.recoveryAttempts += 1
        if session.manifest.recoveryAttempts > maxRecoveryAttempts {
            NSLog("[MapleReplay] discarding spool \(session.manifest.sessionId): recovery kept failing")
            try? FileManager.default.removeItem(at: session.directory)
            return nil
        }
        if let data = try? JSONEncoder().encode(session.manifest) {
            try? data.write(
                to: session.directory.appendingPathComponent(FrameSpool.manifestName),
                options: .atomic
            )
        }

        let frames = session.capturedFrames()
        guard !frames.isEmpty else {
            try? FileManager.default.removeItem(at: session.directory)
            return nil
        }

        let manifest = session.manifest
        let start = frames.first?.timestamp ?? manifest.startDate
        let end = frames.last?.timestamp ?? start
        let options = manifest.encodeOptions
        let seq = manifest.nextChunkSeq

        let writer = SegmentWriter(
            directory: root.appendingPathComponent(manifest.sessionId, isDirectory: true),
            sessionId: manifest.sessionId,
            persistToDisk: persistToDisk
        )

        do {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("maple-recovered-\(manifest.sessionId)-\(seq).mp4")
            let video = try VideoEncoder.encode(frames: frames, options: options, to: temporaryURL)

            let events = SegmentEvents.build(
                sessionId: manifest.sessionId,
                chunkSeq: seq,
                video: video,
                start: start,
                reason: "crash",
                extra: [
                    // The marker that tells anyone reading this segment why it exists,
                    // and that its tail is where the process died. Touch events are not
                    // here: they only ever lived in memory, so a recovered segment is
                    // video and timing only.
                    .breadcrumb(
                        timestamp: end,
                        category: "replay.crash_recovery",
                        message: "recovered in-flight segment from previous launch",
                        data: [
                            "frameCount": frames.count,
                            "spooledBytes": session.byteSize,
                            "attempt": manifest.recoveryAttempts,
                        ]
                    )
                ]
            )

            let segment = try writer.prepare(
                video: video, events: events, chunkSeq: seq, isCheckpoint: true
            )

            // Close out the session row too. The `active` row posted at that session's
            // start is complete by design, but a session that never ends stays open
            // forever; the last spooled frame is the best end time available.
            let endedRow = SessionMetaRow(
                sessionId: manifest.sessionId,
                startedAt: manifest.startDate,
                status: .ended,
                version: 2,
                serviceName: manifest.serviceName,
                environment: manifest.environment,
                userId: manifest.userId,
                recorded: true
            )
            if persistToDisk { endedRow.append(to: writer.directory, now: end) }

            try? FileManager.default.removeItem(at: session.directory)
            return RecoveredSession(
                sessionId: manifest.sessionId,
                segment: segment,
                endedRow: endedRow,
                endedAt: end
            )
        } catch {
            NSLog("[MapleReplay] recovery of \(manifest.sessionId) failed: \(error)")
            return nil
        }
    }
}
