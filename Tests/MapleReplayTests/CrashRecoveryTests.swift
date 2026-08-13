import AVFoundation
import UIKit
import XCTest
@testable import MapleReplay

/// Frames here are real JPEGs, not `Data(repeating:)`: recovery reads dimensions out of
/// the JPEG header and hands the bytes to AVAssetWriter, so a fake byte blob would pass
/// the spool tests and fail the only ones that matter.
private func jpegFrame(at offset: TimeInterval, size: CGSize = CGSize(width: 64, height: 128)) -> CapturedFrame {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
        UIColor(white: CGFloat(offset).truncatingRemainder(dividingBy: 1), alpha: 1).setFill()
        context.fill(CGRect(origin: .zero, size: size))
    }
    return CapturedFrame(
        jpeg: image.jpegData(compressionQuality: 0.6)!,
        timestamp: Date(timeIntervalSince1970: 1_700_000_000 + offset),
        size: size
    )
}

/// Disk output is on for every test in this file, so both URLs are always present.
private extension SegmentArtifacts {
    var videoFile: URL { videoURL! }
    var chunkFile: URL { chunkURL! }
}

private func manifest(sessionId: String, nextChunkSeq: Int = 0, attempts: Int = 0) -> SpoolManifest {
    SpoolManifest(
        sessionId: sessionId,
        startedAt: 1_700_000_000,
        frameRate: 1,
        quality: ReplayQuality.low.rawValue,
        serviceName: "tests",
        environment: "test",
        userId: "u1",
        nextChunkSeq: nextChunkSeq,
        recoveryAttempts: attempts
    )
}

final class FrameSpoolTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maple-spool-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func spool(
        sessionId: String = "session-a",
        capacity: Int = 3,
        byteBudget: Int = 1 << 20
    ) -> FrameSpool {
        FrameSpool(
            root: root,
            manifest: manifest(sessionId: sessionId),
            capacity: capacity,
            byteBudget: byteBudget
        )
    }

    func testSpoolsEveryFrameNotASample() {
        // The disk copy has to be complete: recovery of a partial window is a bug that
        // only shows up as a short video after a real crash.
        let spool = self.spool(capacity: 10)
        for index in 0..<7 { spool.append(jpegFrame(at: TimeInterval(index))) }

        let recovered = SpooledSession.read(directory: spool.directory)
        XCTAssertEqual(recovered?.frames.count, 7)
        XCTAssertEqual(recovered?.capturedFrames().count, 7)
    }

    func testEvictsOldestOnTheRingBufferPolicy() {
        let spool = self.spool(capacity: 3)
        for index in 0..<5 { spool.append(jpegFrame(at: TimeInterval(index))) }

        XCTAssertEqual(spool.frameCount, 3)
        let frames = SpooledSession.read(directory: spool.directory)?.frames ?? []
        XCTAssertEqual(frames.map(\.sequence), [2, 3, 4])
        // Disk agrees with the in-memory count — no orphaned files left behind.
        XCTAssertEqual(frames.count, 3)
    }

    func testByteBudgetBoundsDiskUsageIndependentlyOfFrameCount() {
        let spool = self.spool(capacity: 100, byteBudget: 1)
        for index in 0..<4 { spool.append(jpegFrame(at: TimeInterval(index))) }

        // The budget never evicts the last frame — a spool of nothing recovers nothing.
        XCTAssertEqual(spool.frameCount, 1)
        XCTAssertLessThanOrEqual(SpooledSession.read(directory: spool.directory)?.frames.count ?? 0, 1)
    }

    func testClearFramesLeavesTheManifestWithTheNextSequence() {
        let spool = self.spool()
        for index in 0..<3 { spool.append(jpegFrame(at: TimeInterval(index))) }
        spool.clearFrames(nextChunkSeq: 4)

        let recovered = SpooledSession.read(directory: spool.directory)
        XCTAssertEqual(recovered?.frames.count, 0)
        XCTAssertEqual(recovered?.manifest.nextChunkSeq, 4)
    }

    func testRemoveDeletesTheDirectory() {
        let spool = self.spool()
        spool.append(jpegFrame(at: 0))
        spool.remove()

        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.directory.path))
        XCTAssertNil(SpooledSession.read(directory: spool.directory))
    }

    func testFrameNameRoundTrips() {
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000.125)
        let name = FrameSpool.frameName(sequence: 42, timestamp: timestamp)
        let parsed = FrameSpool.parseFrameName(name)

        XCTAssertEqual(parsed?.sequence, 42)
        XCTAssertEqual(parsed?.timestamp.timeIntervalSince1970 ?? 0, 1_700_000_000.125, accuracy: 0.001)
        // Zero padding means lexicographic order is capture order.
        XCTAssertLessThan(
            FrameSpool.frameName(sequence: 9, timestamp: timestamp),
            FrameSpool.frameName(sequence: 10, timestamp: timestamp)
        )
        // Atomic writes leave temporary siblings; only .jpg files are frames.
        XCTAssertNil(FrameSpool.parseFrameName("manifest.json"))
        XCTAssertNil(FrameSpool.parseFrameName(".dat.nosync0001.abc"))
    }
}

final class CrashRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("maple-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Simulate a session that captured frames and then died without calling `stop()`.
    @discardableResult
    private func crashedSession(
        id: String,
        frames: Int,
        nextChunkSeq: Int = 0,
        attempts: Int = 0
    ) -> FrameSpool {
        let spool = FrameSpool(
            root: root,
            manifest: manifest(sessionId: id, nextChunkSeq: nextChunkSeq, attempts: attempts),
            capacity: 60,
            byteBudget: 1 << 20
        )
        for index in 0..<frames { spool.append(jpegFrame(at: TimeInterval(index))) }
        return spool
    }

    /// Recovery with disk output on, which is what lets these tests read the segment
    /// back. The live path uploads the same `PreparedSegment` and writes nothing.
    private func recover(activeSessionId: String? = nil, budget: Int = 1 << 24) -> [SegmentArtifacts] {
        CrashRecovery.recoverPendingSessions(
            root: root,
            activeSessionId: activeSessionId,
            limits: CrashRecovery.Limits(totalByteBudget: budget),
            persistToDisk: true,
            onRecovered: { _ in }
        )
        .map(\.segment.artifacts)
    }

    func testRecoversAnUnfinishedSessionAsAPlayableSegment() throws {
        let spool = crashedSession(id: "crashed", frames: 5)

        let artifacts = recover()
        XCTAssertEqual(artifacts.count, 1)
        let artifact = try XCTUnwrap(artifacts.first)
        XCTAssertEqual(artifact.frameCount, 5)

        // The segment lands in the *crashed* session's directory, alongside the meta row
        // that session already wrote — it belongs to that session, not to this launch.
        XCTAssertEqual(artifact.videoFile.deletingLastPathComponent().lastPathComponent, "crashed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.videoFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: artifact.chunkFile.path))

        // And it is a real, decodable video, not just bytes on disk.
        let track = AVURLAsset(url: artifact.videoFile).tracks(withMediaType: .video).first
        XCTAssertNotNil(track)

        // Recovery is not repeatable: the spool is gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.directory.path))
        XCTAssertTrue(recover().isEmpty)
    }

    func testRecoveredSegmentCarriesTheCrashBreadcrumb() throws {
        crashedSession(id: "crashed", frames: 3)
        let artifact = try XCTUnwrap(recover().first)

        let json = try XCTUnwrap(Gzip.decompress(try Data(contentsOf: artifact.chunkFile)))
        let events = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [[String: Any]]
        )

        let breadcrumbs = events.compactMap { event -> [String: Any]? in
            guard let data = event["data"] as? [String: Any],
                  data["tag"] as? String == "breadcrumb",
                  let payload = data["payload"] as? [String: Any] else { return nil }
            return payload
        }
        XCTAssertTrue(breadcrumbs.contains { $0["category"] as? String == "replay.crash_recovery" })
        // The ordinary segment breadcrumb is still there, with the reason set to crash,
        // so a consumer that only knows about `replay.segment` still reads this segment.
        XCTAssertTrue(
            breadcrumbs.contains {
                $0["category"] as? String == "replay.segment" && $0["message"] as? String == "crash"
            }
        )
    }

    func testRecoveredSegmentContinuesTheCrashedSessionsSequence() throws {
        crashedSession(id: "crashed", frames: 2, nextChunkSeq: 7)
        let artifact = try XCTUnwrap(recover().first)

        // Segment 7, not segment 0 — segments 0…6 were already emitted before the crash.
        XCTAssertEqual(artifact.chunkSeq, 7)
        XCTAssertEqual(artifact.videoFile.lastPathComponent, "segment-007.mp4")
    }

    func testRecoveryClosesTheSessionMetaRow() throws {
        crashedSession(id: "crashed", frames: 3)
        let artifact = try XCTUnwrap(recover().first)

        let metaURL = artifact.videoFile.deletingLastPathComponent().appendingPathComponent("meta.ndjson")
        let lines = try String(contentsOf: metaURL, encoding: .utf8)
            .split(separator: "\n")
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?["status"] as? String, "ended")
        XCTAssertEqual(lines.first?["session_id"] as? String, "crashed")
        // End time is the last spooled frame, not the moment recovery ran.
        XCTAssertEqual(
            lines.first?["end_time"] as? String,
            SessionMetaRow.clickHouseDateTime(Date(timeIntervalSince1970: 1_700_000_002))
        )
    }

    func testTheLiveSessionsSpoolIsNeverTouched() {
        let live = crashedSession(id: "live", frames: 3)
        crashedSession(id: "crashed", frames: 3)

        let artifacts = recover(activeSessionId: "live")
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.directory.path))
    }

    func testEmptySpoolIsDiscardedRatherThanRecovered() {
        let spool = crashedSession(id: "crashed", frames: 0)

        XCTAssertTrue(recover().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.directory.path))
    }

    // MARK: - Disk bounds

    func testCrashLoopIsBoundedByKeepingOnlyTheNewestSpools() {
        // Three launches, three crashes. Only the newest `maxRecoverableSessions`
        // survive; the rest are deleted before any encoding work begins.
        for (index, id) in ["oldest", "middle", "newest"].enumerated() {
            let spool = FrameSpool(
                root: root,
                manifest: SpoolManifest(
                    sessionId: id,
                    startedAt: 1_700_000_000 + TimeInterval(index * 100),
                    frameRate: 1,
                    quality: ReplayQuality.low.rawValue,
                    serviceName: "tests",
                    environment: nil,
                    userId: "",
                    nextChunkSeq: 0,
                    recoveryAttempts: 0
                ),
                capacity: 60,
                byteBudget: 1 << 20
            )
            spool.append(jpegFrame(at: 0))
        }

        let pending = CrashRecovery.pendingSessions(root: root, activeSessionId: nil)
        XCTAssertEqual(pending.map(\.manifest.sessionId), ["newest", "middle", "oldest"])

        let kept = CrashRecovery.prune(
            pending, limits: CrashRecovery.Limits(totalByteBudget: 1 << 24)
        )
        XCTAssertEqual(kept.map(\.manifest.sessionId), ["newest", "middle"])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: FrameSpool.sessionDirectory(root: root, sessionId: "oldest").path
            )
        )
    }

    func testTotalByteBudgetDropsSpoolsThatWouldNotFit() {
        crashedSession(id: "a", frames: 4)
        crashedSession(id: "b", frames: 4)

        // A budget below one spool's size keeps nothing, and leaves nothing on disk.
        let artifacts = recover(budget: 1)
        XCTAssertTrue(artifacts.isEmpty)
        let spoolRoot = FrameSpool.spoolRoot(in: root)
        let remaining = try? FileManager.default.contentsOfDirectory(atPath: spoolRoot.path)
        XCTAssertEqual(remaining?.count, 0)
    }

    func testASpoolThatKeepsFailingIsEventuallyDiscarded() {
        // Recovery already burned its attempts on previous launches. This is the guard
        // against a frame set that crashes the encoder being retried forever.
        let spool = crashedSession(
            id: "poison", frames: 3, attempts: CrashRecovery.maxRecoveryAttempts
        )

        XCTAssertTrue(recover().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: spool.directory.path))
    }

    func testRecoveryAttemptIsRecordedBeforeTheWorkNotAfter() throws {
        let spool = crashedSession(id: "crashed", frames: 2)
        // Read the manifest the way the next launch would, mid-recovery: the count has to
        // already be durable, or a crash during encoding is invisible and repeats.
        let session = try XCTUnwrap(SpooledSession.read(directory: spool.directory))
        XCTAssertEqual(session.manifest.recoveryAttempts, 0)

        let artifact = try XCTUnwrap(recover().first)
        let json = try XCTUnwrap(Gzip.decompress(try Data(contentsOf: artifact.chunkFile)))
        let events = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [[String: Any]])
        let attempt = events.compactMap { event -> Int? in
            guard let data = event["data"] as? [String: Any],
                  let payload = data["payload"] as? [String: Any],
                  payload["category"] as? String == "replay.crash_recovery",
                  let crumb = payload["data"] as? [String: Any] else { return nil }
            return crumb["attempt"] as? Int
        }.first
        XCTAssertEqual(attempt, 1)
    }

    func testCorruptOrForeignDirectoriesAreIgnored() throws {
        let stray = FrameSpool.spoolRoot(in: root).appendingPathComponent("not-ours", isDirectory: true)
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try Data("nonsense".utf8).write(to: stray.appendingPathComponent(FrameSpool.manifestName))

        XCTAssertNil(SpooledSession.read(directory: stray))
        XCTAssertTrue(CrashRecovery.pendingSessions(root: root, activeSessionId: nil).isEmpty)
    }
}
