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
        /// Usually one. More when the device rotated inside the spooled window, because a
        /// video track has a single size.
        let segments: [PreparedSegment]
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
        removeUnreadableSpools(root: root, activeSessionId: activeSessionId)
        removeStaleTemporaryFiles()
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
            .filter { !isActive($0, activeSessionId: activeSessionId) }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap(SpooledSession.read)
            .filter { $0.manifest.sessionId != activeSessionId }
            .sorted { $0.manifest.startedAt > $1.manifest.startedAt }
    }

    private static func isActive(_ directory: URL, activeSessionId: String?) -> Bool {
        guard let activeSessionId else { return false }
        let name = directory.lastPathComponent
        return name == activeSessionId || name.hasPrefix(activeSessionId + ".")
    }

    /// Delete spool entries no recovery can read: a directory whose manifest is missing
    /// or corrupt (a crash between `createDirectory` and the manifest write, a torn disk),
    /// or a stray file.
    ///
    /// They would otherwise stay forever, invisible to the byte budget, because the
    /// budget only counts spools it can read.
    static func removeUnreadableSpools(root: URL, activeSessionId: String?) {
        let spoolRoot = FrameSpool.spoolRoot(in: root)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: spoolRoot, includingPropertiesForKeys: [.isDirectoryKey], options: []
        )) ?? []
        for entry in entries where !isActive(entry, activeSessionId: activeSessionId) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if !isDirectory || SpooledSession.read(directory: entry) == nil {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    /// Encoder scratch files a crash interrupted. Old enough that no live encode in this
    /// process can own them: one encode is bounded by `VideoEncoder.stepTimeout` per step.
    static func removeStaleTemporaryFiles(
        in directory: URL = FileManager.default.temporaryDirectory,
        olderThan age: TimeInterval = 600,
        now: Date = Date()
    ) {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        )) ?? []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix("maple-segment-") || name.hasPrefix("maple-recovered-"),
                  name.hasSuffix(".mp4") else { continue }
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if now.timeIntervalSince(modified) > age {
                try? FileManager.default.removeItem(at: entry)
            }
        }
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
        session.manifest.recoveryAttempts = max(0, min(session.manifest.recoveryAttempts, maxRecoveryAttempts)) + 1
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
        let end = frames.last?.timestamp ?? manifest.startDate
        let options = manifest.encodeOptions

        let writer = SegmentWriter(
            directory: root.appendingPathComponent(manifest.sessionId, isDirectory: true),
            sessionId: manifest.sessionId,
            persistToDisk: persistToDisk
        )

        let runs = frames.runsOfEqualSize()
        // The manifest is read off disk, so every number in it is untrusted.
        let firstSeq = min(max(0, manifest.nextChunkSeq), Int(UInt32.max) - runs.count)
        var segments: [PreparedSegment] = []
        var failedRuns = 0
        for (index, run) in runs.enumerated() {
            let seq = firstSeq + index
            guard let start = run.first?.timestamp else { continue }
            let isLast = index == runs.count - 1
            do {
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("maple-recovered-\(manifest.sessionId)-\(seq).mp4")
                let video = try VideoEncoder.encode(frames: run, options: options, to: temporaryURL)

                // The marker that tells anyone reading this segment why it exists, and
                // that its tail is where the process died. Touch events are not here: they
                // only ever lived in memory, so a recovered segment is video and timing only.
                let marker: [RRWebEvent] = isLast ? [
                    .breadcrumb(
                        timestamp: end,
                        category: "replay.crash_recovery",
                        message: "recovered in-flight segment from previous launch",
                        data: [
                            "frameCount": frames.count,
                            "spooledBytes": session.byteSize,
                            "attempt": manifest.recoveryAttempts,
                        ]
                    ),
                ] : []
                let events = SegmentEvents.build(
                    sessionId: manifest.sessionId,
                    chunkSeq: seq,
                    video: video,
                    start: start,
                    reason: "crash",
                    extra: marker
                )
                segments.append(
                    try writer.prepare(video: video, events: events, chunkSeq: seq, isCheckpoint: true)
                )
            } catch {
                failedRuns += 1
                NSLog("[MapleReplay] recovery of \(manifest.sessionId) segment \(seq) failed: \(error)")
            }
        }
        // Nothing encoded: leave the spool for the next launch, which the attempt count
        // above bounds.
        guard !segments.isEmpty else { return nil }
        // A partial result is kept for a later attempt while attempts remain: deleting the
        // spool now would lose the runs that failed, which may be a transient writer stall.
        if failedRuns > 0, manifest.recoveryAttempts < maxRecoveryAttempts { return nil }

        // Close out the session row too. A session that never ends stays open forever,
        // and the last spooled frame is the best end time available.
        let startedAt = manifest.startDate <= (frames.first?.timestamp ?? end) ? manifest.startDate : (frames.first?.timestamp ?? end)
        let endedRow = SessionMetaRow(
            sessionId: manifest.sessionId,
            startedAt: SessionMetaRow.clampedToColumnRange(startedAt),
            status: .ended,
            version: recoveredRowVersion(),
            serviceName: manifest.serviceName,
            environment: manifest.environment,
            userId: manifest.userId,
            recorded: true,
            replayTrigger: manifest.mode == ReplayMode.buffer.rawValue ? "error" : nil
        )
        if persistToDisk { endedRow.append(to: writer.directory, now: end) }

        try? FileManager.default.removeItem(at: session.directory)
        return RecoveredSession(
            sessionId: manifest.sessionId,
            segments: segments,
            endedRow: endedRow,
            endedAt: end
        )
    }

    /// Version for the row that closes a crashed session.
    ///
    /// The table keeps the highest version, and the crashed process posted an unknown
    /// number of rows (a resume or a promotion each posts one). This row is the last word
    /// on that session, so it takes a version no live counter reaches: the epoch second,
    /// which fits the column's UInt32 until 2106.
    static func recoveredRowVersion(now: Date = Date()) -> Int {
        max(3, Int(min(now.timeIntervalSince1970, Double(UInt32.max))))
    }
}
