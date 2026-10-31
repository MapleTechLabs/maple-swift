import AVFoundation
import Foundation
import MapleCore
import XCTest
@testable import MapleReplay

/// Random spool trees against `CrashRecovery.recoverPendingSessions`.
///
/// The tree builder keeps its own record of what it wrote, so every oracle compares the
/// SDK's result with the builder's intent rather than with a second reading of the SDK.
final class FuzzCrashRecoveryTests: XCTestCase {
    private struct Candidate {
        let directory: URL
        let manifest: SpoolManifest
        let frameBytes: Int
        /// At least one intact JPEG and an id the gateway accepts.
        let mustRecover: Bool
    }

    private struct Tree {
        let root: URL
        let activeId: String
        var candidates: [Candidate] = []
        var activeSnapshot: [String: Data] = [:]
        var spoolRootIsFile = false
        var log: [String] = []
    }

    private let sizes = [(32, 32), (64, 48), (48, 64)]

    private func manifestData(_ manifest: SpoolManifest) -> Data { try! JSONEncoder().encode(manifest) }

    private func randomManifest(_ rng: inout FuzzRNG, sessionId: String, startedAt: TimeInterval) -> SpoolManifest {
        SpoolManifest(
            sessionId: sessionId,
            startedAt: startedAt,
            frameRate: rng.chance(0.2) ? rng.pick([Int.min, -1, 0, 1_000, Int.max]) : rng.int(1...10),
            quality: rng.pick(["low", "medium", "high", "", "garbage"]),
            serviceName: rng.hostileString(maxFragments: 6),
            environment: rng.chance(0.3) ? nil : rng.hostileString(maxFragments: 4),
            userId: rng.hostileString(maxFragments: 4),
            // Bounded: Int.max here traps (see the trap tests below), and the general
            // fuzzer has to keep running to find anything else.
            nextChunkSeq: rng.chance(0.2) ? rng.pick([0, -5, 1_000_000]) : rng.int(0...50),
            recoveryAttempts: rng.pick([-3, 0, 0, 0, 1, 1, 2, 3]),
            mode: rng.pick([nil, "record", "buffer", "off", "nonsense"])
        )
    }

    /// Writes frames into `directory`; returns (frame-named bytes, has intact JPEG).
    private func writeFrames(_ rng: inout FuzzRNG, into directory: URL, start: TimeInterval, log: inout [String]) -> (Int, Bool) {
        var bytes = 0
        var intact = false
        var sequence = rng.int(0...5)
        var time = start
        let (width, height) = rng.pick(sizes)
        for _ in 0..<rng.int(0...5) {
            sequence += rng.int(1...3)
            time += rng.double(0.5..<2)
            let name = FrameSpool.frameName(sequence: sequence, timestamp: Date(timeIntervalSince1970: time))
            let url = directory.appendingPathComponent(name)
            let size = rng.chance(0.15) ? rng.pick(sizes) : (width, height)
            let jpeg = FuzzFixtures.jpeg(width: size.0, height: size.1, shade: sequence)
            switch rng.int(0...9) {
            case 0:
                try? Data().write(to: url); log.append("zero-byte frame")
            case 1:
                try? jpeg.prefix(jpeg.count / 2).write(to: url); log.append("truncated frame")
            case 2:
                try? rng.bytes(rng.int(1...300)).write(to: url); log.append("garbage frame")
            case 3:
                try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); log.append("dir named as frame")
            default:
                try? jpeg.write(to: url); intact = true
            }
            bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        // Clutter that is not a frame and must be ignored.
        for _ in 0..<rng.int(0...2) {
            let name = rng.pick(["notes.txt", ".DS_Store", "segment-000.json.gz", "1-2.png", "frame.jpg", "x-y.jpg", rng.asciiIdentifier()])
            try? rng.bytes(rng.int(0...200)).write(to: directory.appendingPathComponent(name))
        }
        if rng.chance(0.1) {
            let nested = directory.appendingPathComponent("nested/deeper", isDirectory: true)
            try? FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try? FuzzFixtures.jpeg(width: 16, height: 16).write(to: nested.appendingPathComponent("000000001-0001700000000000.jpg"))
        }
        return (bytes, intact)
    }

    private func snapshot(_ directory: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) else { return out }
        for case let url as URL in enumerator {
            let relative = String(url.path.dropFirst(directory.path.count))
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            out[relative] = isDirectory ? Data("<dir>".utf8) : ((try? Data(contentsOf: url)) ?? Data("<unreadable>".utf8))
        }
        return out
    }

    private func buildTree(_ rng: inout FuzzRNG) -> Tree {
        let root = FuzzFixtures.temporaryDirectory("recovery")
        let spoolRoot = FrameSpool.spoolRoot(in: root)
        var tree = Tree(root: root, activeId: "active-" + rng.asciiIdentifier(maxLength: 8))

        if rng.chance(0.04) {
            try? Data("not a directory".utf8).write(to: spoolRoot)
            tree.spoolRootIsFile = true
            tree.log.append("spool root is a file")
            return tree
        }
        try? FileManager.default.createDirectory(at: spoolRoot, withIntermediateDirectories: true)

        // The live session's spool, plus a resumed run of it, neither of which may change.
        if rng.chance(0.7) {
            for name in rng.chance(0.3) ? [tree.activeId, tree.activeId + ".1"] : [tree.activeId] {
                let directory = spoolRoot.appendingPathComponent(name, isDirectory: true)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let manifest = randomManifest(&rng, sessionId: tree.activeId, startedAt: 1_800_000_000)
                if rng.chance(0.8) { try? manifestData(manifest).write(to: directory.appendingPathComponent(FrameSpool.manifestName)) }
                _ = writeFrames(&rng, into: directory, start: 1_800_000_000, log: &tree.log)
            }
            tree.activeSnapshot = snapshot(spoolRoot)
        }

        var usedStarts = Set<Int>()
        for index in 0..<rng.int(0...7) {
            let id = rng.chance(0.08) ? rng.hostileString(maxFragments: 4) : "s\(index)-" + rng.asciiIdentifier(maxLength: 10)
            let exotic = !id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            var start = 0
            repeat { start = rng.int(-1_000_000...2_000_000_000) } while !usedStarts.insert(start).inserted
            var dirName = exotic ? "exotic-\(index)" : (rng.chance(0.2) ? "\(id).\(rng.int(1...4))" : id)
            if rng.chance(0.05) { dirName = "renamed-\(index)" }
            let directory = spoolRoot.appendingPathComponent(dirName, isDirectory: true)

            switch rng.int(0...11) {
            case 0:
                try? rng.bytes(rng.int(0...100)).write(to: directory)  // stray file at the spool root
                tree.log.append("stray file")
            case 1:
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                _ = writeFrames(&rng, into: directory, start: Double(start), log: &tree.log)
                tree.log.append("no manifest")
            case 2:
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let valid = manifestData(randomManifest(&rng, sessionId: id, startedAt: Double(start)))
                let corrupt: Data = rng.pick([
                    valid.prefix(rng.int(0...max(0, valid.count - 1))),
                    rng.bytes(rng.int(0...200)),
                    Data(#"{"sessionId": 5, "startedAt": "yesterday"}"#.utf8),
                    Data("[]".utf8),
                ])
                try? corrupt.write(to: directory.appendingPathComponent(FrameSpool.manifestName))
                _ = writeFrames(&rng, into: directory, start: Double(start), log: &tree.log)
                tree.log.append("corrupt manifest")
            case 3:
                try? FileManager.default.createDirectory(
                    at: directory.appendingPathComponent(FrameSpool.manifestName, isDirectory: true), withIntermediateDirectories: true)
                tree.log.append("manifest is a directory")
            case 4:
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                tree.log.append("empty dir")
            default:
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let manifest = randomManifest(&rng, sessionId: id, startedAt: Double(start))
                var data = manifestData(manifest)
                if rng.chance(0.1), var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    object["unknownFutureField"] = rng.jsonValue(depth: 2)  // forward-compatible extra key
                    data = (try? JSONSerialization.data(withJSONObject: object)) ?? data
                }
                try? data.write(to: directory.appendingPathComponent(FrameSpool.manifestName))
                let (bytes, intact) = writeFrames(&rng, into: directory, start: Double(start), log: &tree.log)
                tree.candidates.append(Candidate(
                    directory: directory, manifest: manifest, frameBytes: bytes,
                    mustRecover: intact && !exotic && SegmentWriter.isSafeSessionId(manifest.sessionId)
                        && manifest.recoveryAttempts + 1 <= CrashRecovery.maxRecoveryAttempts
                ))
                tree.log.append("valid spool \(id.debugDescription) bytes=\(bytes) intact=\(intact) attempts=\(manifest.recoveryAttempts)")
            }
        }
        return tree
    }

    /// Decodes the MP4 carried in a segment and counts the frames that actually decode.
    private func decodedFrameCount(base64: String) throws -> Int {
        guard let mp4 = Data(base64Encoded: base64), !mp4.isEmpty else { throw FuzzFailure(description: "video base64 empty or invalid") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("maple-fuzz-decode-\(UUID().uuidString).mp4")
        try mp4.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw FuzzFailure(description: "no video track") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw FuzzFailure(description: "reader failed: \(String(describing: reader.error))") }
        var count = 0
        while let sample = output.copyNextSampleBuffer() {
            if CMSampleBufferGetImageBuffer(sample) != nil { count += 1 }
        }
        return count
    }

    private func checkSegment(_ segment: PreparedSegment, manifest: SpoolManifest, index: Int) throws {
        guard let json = Gzip.decompress(segment.body),
              let events = try JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
            throw FuzzFailure(description: "segment body is not gzipped JSON")
        }
        try Fuzz.check(events.first?["type"] as? Int == 4, "first event is not meta")
        let stamps = events.compactMap { $0["timestamp"] as? Int }
        try Fuzz.check(stamps.count == events.count && zip(stamps, stamps.dropFirst()).allSatisfy { $0 <= $1 }, "timestamps not ordered")
        guard let video = events.compactMap({ ($0["data"] as? [String: Any]).flatMap { $0["tag"] as? String == "video" ? $0["payload"] as? [String: Any] : nil } }).first,
              let base64 = video["base64"] as? String, let frameCount = video["frameCount"] as? Int else {
            throw FuzzFailure(description: "no video event")
        }
        let decoded = try decodedFrameCount(base64: base64)
        try Fuzz.check(frameCount >= 1 && decoded == frameCount, "video decodes \(decoded) frames, payload says \(frameCount)")
        try Fuzz.check(segment.artifacts.chunkSeq >= manifest.nextChunkSeq, "chunk seq \(segment.artifacts.chunkSeq) below manifest's \(manifest.nextChunkSeq)")
    }

    func testRecoveryOnRandomSpoolTrees() {
        // Coverage guard: a generator that never yields a recoverable spool would let
        // every oracle below pass vacuously.
        var recoveredSegments = 0
        defer { if Fuzz.caseSeedOverride == nil { XCTAssertGreaterThan(recoveredSegments, 0, "no tree produced a recovered segment") } }
        Fuzz.run("crashRecovery", iterations: Fuzz.iterations(cost: 25, minimum: 60)) { rng in
            var tree = buildTree(&rng)
            defer { try? FileManager.default.removeItem(at: tree.root) }
            let totalBytes = tree.candidates.reduce(0) { $0 + $1.frameBytes }
            let limits = CrashRecovery.Limits(
                totalByteBudget: rng.chance(0.2) ? rng.pick([0, 1, Int.max]) : rng.int(0...max(1, totalBytes * 2)),
                maxSessions: rng.pick([-1, 0, 1, 2, 3])
            )
            tree.log.append("limits bytes=\(limits.totalByteBudget) sessions=\(limits.maxSessions)")
            let context = { tree.log.joined(separator: "; ") }

            var callbacks: [CrashRecovery.RecoveredSession] = []
            let recovered = CrashRecovery.recoverPendingSessions(
                root: tree.root, activeSessionId: tree.activeId, limits: limits, persistToDisk: false
            ) { callbacks.append($0) }

            try Fuzz.check(recovered.map(\.sessionId) == callbacks.map(\.sessionId), "callback and return value disagree")
            try Fuzz.check(recovered.count <= max(0, limits.maxSessions), "\(recovered.count) recovered over limit: \(context())")

            // Reference prune: newest first, greedy under both limits.
            var kept: [Candidate] = []
            var total = 0
            // Spools under an id the gateway rejects are unreadable to recovery and deleted.
            let readable = tree.candidates.filter { SegmentWriter.isSafeSessionId($0.manifest.sessionId) }
            for candidate in readable.sorted(by: { $0.manifest.startedAt > $1.manifest.startedAt }) {
                if kept.count < max(0, limits.maxSessions), total + candidate.frameBytes <= limits.totalByteBudget {
                    kept.append(candidate); total += candidate.frameBytes
                }
            }
            let keptIds = Set(kept.map(\.manifest.sessionId))
            let recoveredIds = Set(recovered.map(\.sessionId))
            try Fuzz.check(recoveredIds.isSubset(of: keptIds), "recovered \(recoveredIds.subtracting(keptIds)) outside the budget: \(context())")
            let recoveredBytes = tree.candidates.filter { recoveredIds.contains($0.manifest.sessionId) }.reduce(0) { $0 + $1.frameBytes }
            try Fuzz.check(recoveredBytes <= limits.totalByteBudget, "recovered \(recoveredBytes) bytes over \(limits.totalByteBudget): \(context())")
            for candidate in kept where candidate.mustRecover {
                try Fuzz.check(recoveredIds.contains(candidate.manifest.sessionId),
                               "intact spool \(candidate.manifest.sessionId) within budget was not recovered: \(context())")
            }

            for session in recovered {
                guard let manifest = tree.candidates.first(where: { $0.manifest.sessionId == session.sessionId })?.manifest else {
                    throw FuzzFailure(description: "recovered unknown session \(session.sessionId.debugDescription)")
                }
                try Fuzz.check(!session.segments.isEmpty, "recovered session without segments")
                recoveredSegments += session.segments.count
                for (index, segment) in session.segments.enumerated() { try checkSegment(segment, manifest: manifest, index: index) }
                let line = try session.endedRow.ndjson(now: session.endedAt)
                let row = FuzzJSON.ndjsonObjects(line)?.first
                try Fuzz.check(row?["status"] as? String == "ended" && row?["session_id"] as? String == session.sessionId, "ended row malformed")
            }

            // Afterwards the spool root holds only the live session and spools that are
            // readable and still have recovery attempts left.
            guard !tree.spoolRootIsFile else { return }
            let spoolRoot = FrameSpool.spoolRoot(in: tree.root)
            let remaining = (try? FileManager.default.contentsOfDirectory(at: spoolRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for entry in remaining {
                let name = entry.lastPathComponent
                if name == tree.activeId || name.hasPrefix(tree.activeId + ".") { continue }
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                let manifest = (try? Data(contentsOf: entry.appendingPathComponent(FrameSpool.manifestName)))
                    .flatMap { try? JSONDecoder().decode(SpoolManifest.self, from: $0) }
                try Fuzz.check(isDirectory && manifest != nil, "unreadable entry \(name.debugDescription) left behind: \(context())")
                if let manifest {
                    try Fuzz.check(!recoveredIds.contains(manifest.sessionId), "recovered spool \(name) not deleted")
                    try Fuzz.check(manifest.recoveryAttempts <= CrashRecovery.maxRecoveryAttempts, "exhausted spool \(name) kept")
                }
            }
            let activeAfter = snapshot(spoolRoot).filter { key, _ in
                let first = key.split(separator: "/").first.map(String.init) ?? ""
                return first == tree.activeId || first.hasPrefix(tree.activeId + ".")
            }
            let activeBefore = tree.activeSnapshot.filter { key, _ in
                let first = key.split(separator: "/").first.map(String.init) ?? ""
                return first == tree.activeId || first.hasPrefix(tree.activeId + ".")
            }
            try Fuzz.check(activeAfter == activeBefore, "the live session's spool changed: \(context())")
        }
    }

    // MARK: - Minimised traps found by the fuzzer

    private func writeSpool(root: URL, manifest: SpoolManifest, sizes: [(Int, Int)]) throws {
        let directory = FrameSpool.sessionDirectory(root: root, sessionId: manifest.sessionId)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try manifestData(manifest).write(to: directory.appendingPathComponent(FrameSpool.manifestName))
        for (index, size) in sizes.enumerated() {
            let name = FrameSpool.frameName(sequence: index, timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)))
            try FuzzFixtures.jpeg(width: size.0, height: size.1).write(to: directory.appendingPathComponent(name))
        }
    }

    private func trapManifest(nextChunkSeq: Int = 0, attempts: Int = 0, startedAt: TimeInterval = 1_700_000_000) -> SpoolManifest {
        SpoolManifest(sessionId: "trap", startedAt: startedAt, frameRate: 1, quality: "low", serviceName: "s",
                      environment: nil, userId: "", nextChunkSeq: nextChunkSeq, recoveryAttempts: attempts)
    }

    private func recoverTrap(_ manifest: SpoolManifest, sizes: [(Int, Int)], describe: String) throws {
        let root = FuzzFixtures.temporaryDirectory("trap")
        defer { try? FileManager.default.removeItem(at: root) }
        try writeSpool(root: root, manifest: manifest, sizes: sizes)
        let recovered = CrashRecovery.recoverPendingSessions(
            root: root, activeSessionId: nil, limits: .init(totalByteBudget: .max), persistToDisk: false) { _ in }
        for session in recovered { _ = try session.endedRow.ndjson(now: session.endedAt) }
    }

    func testManifestWithMaxRecoveryAttemptsDoesNotTrap() throws {
        try recoverTrap(trapManifest(attempts: .max), sizes: [(32, 32)],
                        describe: "manifest recoveryAttempts = Int.max overflows `recoveryAttempts += 1` in CrashRecovery.recover (CrashRecovery.swift:170)")
    }

    func testManifestWithMaxChunkSeqAndTwoFrameSizesDoesNotTrap() throws {
        try recoverTrap(trapManifest(nextChunkSeq: .max), sizes: [(32, 32), (64, 48)],
                        describe: "manifest nextChunkSeq = Int.max overflows `manifest.nextChunkSeq + index` for the second size run (CrashRecovery.swift:202)")
    }

    func testManifestWithHugeStartDateDoesNotTrapTheEndedRow() throws {
        try recoverTrap(trapManifest(startedAt: 1e20), sizes: [(32, 32)],
                        describe: "manifest startedAt = 1e20 makes SessionMetaRow.json trap converting duration_ms to Int (SessionMetaRow.swift:152), on the ended row MapleReplay posts after recovery")
    }
}
