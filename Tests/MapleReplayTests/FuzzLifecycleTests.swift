import Foundation
import MapleCore
import XCTest
@testable import MapleReplay

/// Random lifecycle sequences against a fresh `MapleReplay`, checked through the only
/// thing the backend ever sees: the requests.
///
/// Package tests have no key window, so no frames are captured and blobs are rare. The
/// metadata rows and event rows are what this exercises, and they are the billed,
/// user-visible part of a session.
@MainActor
final class FuzzLifecycleTests: XCTestCase {
    private struct MetaRow {
        let sessionId: String
        let version: Int
        let status: String
        let recorded: String?
        let trigger: String?
        let index: Int
    }

    private struct Capture {
        var metas: [MetaRow] = []
        var blobs: [(sessionId: String, seq: String, index: Int)] = []
        var events: [(sessionId: String, seq: Int, index: Int)] = []
        var maxIndex = -1
    }

    private func capture(host: String) -> Capture {
        var out = Capture()
        for request in FuzzStubProtocol.requests where request.host == host {
            out.maxIndex = max(out.maxIndex, request.index)
            switch request.path {
            case "/v1/sessionReplays/meta":
                for object in FuzzJSON.ndjsonObjects(request.body) ?? [] {
                    let attributes = object["resource_attributes"] as? [String: String] ?? [:]
                    out.metas.append(MetaRow(
                        sessionId: object["session_id"] as? String ?? "?",
                        version: (object["version"] as? NSNumber)?.intValue ?? -1,
                        status: object["status"] as? String ?? "?",
                        recorded: attributes["maple.session.recorded"],
                        trigger: attributes["maple.session.replay_trigger"],
                        index: request.index
                    ))
                }
            case "/v1/sessionReplays/blob":
                out.blobs.append((request.headers["x-maple-session-id"] ?? "?", request.headers["x-maple-chunk-seq"] ?? "?", request.index))
            case "/v1/sessionEvents":
                for object in FuzzJSON.ndjsonObjects(request.body) ?? [] {
                    out.events.append((object["session_id"] as? String ?? "?", (object["seq"] as? NSNumber)?.intValue ?? -1, request.index))
                }
            default:
                break
            }
        }
        return out
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Run the main loop until no request for this host has arrived for `quiet` seconds.
    private func settle(host: String, quiet: TimeInterval = 0.15, limit: TimeInterval = 4) {
        let deadline = Date().addingTimeInterval(limit)
        var last = -2
        var stableSince = Date()
        while Date() < deadline {
            pump(0.02)
            let count = FuzzStubProtocol.requests.filter { $0.host == host }.count
            if count != last { last = count; stableSince = Date() }
            if Date().timeIntervalSince(stableSince) >= quiet { return }
        }
    }

    private func latest(_ capture: Capture, _ sessionId: String) -> MetaRow? {
        capture.metas.filter { $0.sessionId == sessionId }.max { $0.version < $1.version }
    }

    func testRandomLifecycleSequences() {
        Fuzz.run("lifecycle", iterations: Fuzz.iterations(cost: 50, minimum: 4)) { rng in
            try runSequence(&rng)
        }
    }

    private func runSequence(_ rng: inout FuzzRNG) throws {
        let host = "run-\(rng.next() % 1_000_000_000).fuzz.invalid"
        let outputDirectory = FuzzFixtures.temporaryDirectory("lifecycle")
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        SessionSink.shared.resetForTesting()

        let replay = MapleReplay()
        replay.urlSessionOverride = FuzzStubProtocol.session()
        replay.holdsBackgroundTask = false
        let random = FuzzRandomBox(seed: rng.next())
        replay.randomSource = { random.unit() }

        var options = ReplayOptions()
        options.ingestKey = "maple_pk_fuzz"
        options.endpoint = URL(string: "https://\(host)")!
        options.crashRecovery = false
        options.outputDirectory = outputDirectory
        options.segmentDuration = 1
        options.sessionSampleRate = rng.pick([0, 0.5, 1])
        options.onErrorSampleRate = rng.pick([0, 0.5, 1])
        options.backgroundSessionTimeout = rng.pick([0, 0.15, 30])

        var log: [String] = ["rates=\(options.sessionSampleRate)/\(options.onErrorSampleRate) timeout=\(options.backgroundSessionTimeout)"]
        func fail(_ message: String) -> FuzzFailure {
            FuzzFailure(description: "\(message)\n  ops: \(log.joined(separator: ", "))")
        }

        var started = false
        var known = Set<String>()
        var stopWindows: [(after: Int, until: Int?, known: Set<String>)] = []
        var pendingPause: (id: String, start: Date, end: Date)?
        let tracks = DispatchGroup()
        let trackLock = NSLock()
        var trackCount = 0

        func noteLive() { if let id = replay.sessionId { known.insert(id) } }
        func requestIndexNow() -> Int { FuzzStubProtocol.requests.map(\.index).max() ?? -1 }

        replay.start(options: options, serviceName: "fuzz")
        started = true
        log.append("start")
        noteLive()

        for _ in 0..<rng.int(3...12) {
            switch rng.int(0...9) {
            case 0, 1:
                let before = replay.sessionId
                let start = Date()
                replay.handleDidEnterBackground()
                if let before { pendingPause = (before, start, Date()) }
                log.append("background")
                if rng.chance(0.5) { settle(host: host) }
            case 2, 3:
                let delay = rng.pick([0, 0, 0.05, 0.2, 0.35])
                if delay > 0 { pump(delay) }
                let start = Date()
                replay.handleWillEnterForeground()
                let end = Date()
                noteLive()
                log.append("foreground(+\(delay)s)")
                let now = replay.sessionId
                if !started {
                    if now != nil { throw fail("a stopped SDK started session \(now!) on foreground") }
                } else if let pause = pendingPause {
                    let timeout = options.backgroundSessionTimeout
                    if start.timeIntervalSince(pause.end) >= timeout, now == pause.id {
                        throw fail("away \(start.timeIntervalSince(pause.end))s >= timeout \(timeout) but session \(pause.id) resumed")
                    }
                    if end.timeIntervalSince(pause.start) < timeout, now != pause.id {
                        throw fail("away < timeout \(timeout) but session became \(String(describing: now)) instead of resuming \(pause.id)")
                    }
                    if now == nil { throw fail("no live session after foreground") }
                }
                pendingPause = nil
            case 4:
                let trigger = rng.hostileString(maxFragments: 3)
                if rng.chance(0.5) {
                    replay.flush(trigger: trigger)
                } else {
                    DispatchQueue.global().async { replay.flush(trigger: trigger) }
                }
                log.append("flush")
            case 5:
                let threads = rng.int(1...8), each = rng.int(1...12)
                let name = rng.hostileString(maxFragments: 4)
                tracks.enter()
                DispatchQueue.global().async {
                    DispatchQueue.concurrentPerform(iterations: threads) { index in
                        for _ in 0..<each { replay.track(name, properties: ["thread": String(index)]) }
                    }
                    trackLock.lock(); trackCount += threads * each; trackLock.unlock()
                    tracks.leave()
                }
                log.append("track(\(threads)x\(each))")
            case 6:
                replay.setUserId(rng.chance(0.3) ? "" : rng.hostileString(maxFragments: 3))
                log.append("setUserId")
            case 7:
                replay.stop()
                if started { stopWindows.append((requestIndexNow(), nil, known)) }
                started = false
                pendingPause = nil
                log.append("stop")
            case 8:
                let wasStarted = started
                let knownBefore = known
                if !wasStarted, let open = stopWindows.indices.last, stopWindows[open].until == nil {
                    stopWindows[open].until = requestIndexNow()
                }
                replay.start(options: options, serviceName: "fuzz")
                started = true
                log.append(wasStarted ? "start(again)" : "start")
                if !wasStarted {
                    guard let id = replay.sessionId else { throw fail("start() after stop() left no live session") }
                    if knownBefore.contains(id) { throw fail("start() after stop() reused session \(id)") }
                    pendingPause = nil
                }
                noteLive()
            default:
                settle(host: host)
                log.append("settle")
                try checkSettled(capture(host: host), replay: replay, started: started, fail: fail)
            }
        }

        _ = tracks.wait(timeout: .now() + 10)
        replay.stop()
        log.append("stop(final)")
        if started { stopWindows.append((requestIndexNow(), nil, known)) }
        settle(host: host, quiet: 0.25)
        let final = capture(host: host)
        try checkFinal(final, options: options, trackCount: trackCount, stopWindows: stopWindows, fail: fail)

        replay.resetForTesting()
        SessionSink.shared.resetForTesting()
    }

    /// Invariants that must hold whenever the SDK has gone quiet.
    private func checkSettled(_ capture: Capture, replay: MapleReplay, started: Bool, fail: (String) -> FuzzFailure) throws {
        if replay.isRecording, replay.sessionId == nil { throw fail("recording with no live session") }
        if let id = replay.sessionId {
            guard let row = latest(capture, id) else { throw fail("live session \(id) has no metadata row") }
            if row.status != "active" { throw fail("live session \(id) reads as \(row.status) at version \(row.version)") }
        }
        if !started {
            for id in Set(capture.metas.map(\.sessionId)) where latest(capture, id)?.status != "ended" {
                throw fail("stopped SDK left session \(id) \(latest(capture, id)?.status ?? "?")")
            }
        }
    }

    private func checkFinal(
        _ capture: Capture,
        options: ReplayOptions,
        trackCount: Int,
        stopWindows: [(after: Int, until: Int?, known: Set<String>)],
        fail: (String) -> FuzzFailure
    ) throws {
        let sessions = Set(capture.metas.map(\.sessionId))
        for id in sessions {
            let rows = capture.metas.filter { $0.sessionId == id }.sorted { $0.version < $1.version }
            let versions = rows.map(\.version)
            if versions != Array(1...rows.count) { throw fail("session \(id) versions \(versions), expected 1...\(rows.count)") }
            if rows[0].status != "active" { throw fail("session \(id) version 1 is \(rows[0].status)") }
            for (a, b) in zip(rows, rows.dropFirst()) where a.status == "ended" && b.status != "active" {
                throw fail("session \(id): ended v\(a.version) followed by \(b.status) v\(b.version)")
            }
            if rows.last?.status != "ended" { throw fail("session \(id) ends on \(rows.last!.status) v\(rows.last!.version) after stop()") }

            // Recorded only ever goes false -> true, and only a promotion sets the trigger.
            let recorded = rows.map { $0.recorded == "true" }
            if let first = recorded.firstIndex(of: true), recorded[first...].contains(false) {
                throw fail("session \(id) recorded flag regressed: \(recorded)")
            }
            for row in rows where row.recorded == "true" {
                let expected: String? = recorded[0] ? nil : "error"
                if row.trigger != expected { throw fail("session \(id) v\(row.version) trigger \(String(describing: row.trigger)), expected \(String(describing: expected))") }
            }
            if options.sessionSampleRate == 1, !recorded.allSatisfy({ $0 }) { throw fail("rate 1 session \(id) not recorded: \(recorded)") }
            if options.sessionSampleRate == 0, options.onErrorSampleRate == 0, recorded.contains(true) {
                throw fail("unsampled session \(id) reads as recorded")
            }

            let blobSeqs = capture.blobs.filter { $0.sessionId == id }.map(\.seq)
            if Set(blobSeqs).count != blobSeqs.count { throw fail("session \(id) duplicate chunk seqs \(blobSeqs)") }
            if !blobSeqs.isEmpty, !recorded.contains(true) { throw fail("session \(id) uploaded blobs while not recorded") }

            let eventSeqs = capture.events.filter { $0.sessionId == id }.map(\.seq).sorted()
            if eventSeqs != Array(0..<eventSeqs.count) { throw fail("session \(id) event seqs not unique and gap-free: \(eventSeqs.prefix(40))") }
        }
        for orphan in Set(capture.blobs.map(\.sessionId) + capture.events.map(\.sessionId)).subtracting(sessions) {
            throw fail("requests for session \(orphan) that never posted a metadata row")
        }
        if capture.events.count > trackCount { throw fail("\(capture.events.count) events delivered for \(trackCount) tracks") }

        // Between a stop and the next start, only sessions that already existed may speak.
        let traffic = capture.metas.map { ($0.sessionId, $0.index) } + capture.blobs.map { ($0.sessionId, $0.index) }
            + capture.events.map { ($0.sessionId, $0.index) }
        for window in stopWindows {
            for (sessionId, index) in traffic where index > window.after && index <= (window.until ?? .max) {
                if !window.known.contains(sessionId) { throw fail("session \(sessionId) sent a request while stopped") }
            }
        }
    }

    // MARK: - Minimised reproductions of what the fuzzer found

    private func makeReplay(host: String, sessionSampleRate: Double, timeout: TimeInterval = 30) -> (MapleReplay, ReplayOptions) {
        SessionSink.shared.resetForTesting()
        FuzzStubProtocol.reset()
        let replay = MapleReplay()
        replay.urlSessionOverride = FuzzStubProtocol.session()
        replay.holdsBackgroundTask = false
        replay.randomSource = { 0 }
        var options = ReplayOptions()
        options.ingestKey = "maple_pk_fuzz"
        options.endpoint = URL(string: "https://\(host)")!
        options.crashRecovery = false
        options.outputDirectory = FuzzFixtures.temporaryDirectory("lifecycle-min")
        options.sessionSampleRate = sessionSampleRate
        options.onErrorSampleRate = 0
        options.backgroundSessionTimeout = timeout
        return (replay, options)
    }

    /// `stop()` finishes its teardown asynchronously; a `start()` before then must still
    /// begin a new session rather than leave the SDK started with none.
    func testStartImmediatelyAfterStopBeginsASession() {
        let (replay, options) = makeReplay(host: "min-stopstart.fuzz.invalid", sessionSampleRate: 0)
        defer { replay.resetForTesting() }
        replay.start(options: options)
        let first = replay.sessionId
        replay.stop()
        replay.start(options: options)
        XCTAssertNotNil(replay.sessionId, "start() right after stop() left no live session")
        XCTAssertNotEqual(replay.sessionId, first)
        settle(host: "min-stopstart.fuzz.invalid")
        XCTAssertNotNil(replay.sessionId, "still no live session once stop()'s teardown finished")
    }

    /// Resuming must leave the session reading as active. The `ended` row of the pause is
    /// built on the recorder's queue, so a quick return can be overtaken by it.
    func testQuickBackgroundForegroundLeavesSessionActive() {
        let host = "min-bgfg.fuzz.invalid"
        var failures: [String] = []
        for attempt in 0..<20 {
            let (replay, options) = makeReplay(host: host, sessionSampleRate: 1)
            replay.start(options: options)
            replay.handleDidEnterBackground()
            replay.handleWillEnterForeground()
            settle(host: host, quiet: 0.1)
            let rows = capture(host: host)
            if let id = replay.sessionId, let row = latest(rows, id), row.status != "active" {
                failures.append("attempt \(attempt): live session reads \(row.status) at v\(row.version)")
            }
            replay.resetForTesting()
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
