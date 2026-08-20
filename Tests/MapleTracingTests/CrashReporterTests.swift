import XCTest
@testable import MapleCore
@testable import MapleTracing

/// The durability half of crash reporting: MetricKit delivers a payload exactly once, so
/// everything between receiving it and exporting it has to survive being interrupted.
final class CrashReporterTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        // Process-global by design — it models a process-global fact — so a tracer
        // started by another test in this bundle has already claimed it.
        LastSessionStore.resetForTesting()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("maple-crash-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        LastSessionStore.resetForTesting()
        super.tearDown()
    }

    private func payload(signal: Int = 11) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "timeStampEnd": "2026-08-20 09:30:00 +0000",
            "crashDiagnostics": [[
                "diagnosticMetaData": ["exceptionType": 1, "signal": signal, "appVersion": "1.4.2"],
                "callStackTree": ["callStacks": [[
                    "threadAttributed": true,
                    "callStackRootFrames": [[
                        "binaryName": "MyApp", "binaryUUID": "U", "address": 1, "offsetIntoBinaryTextSegment": 2,
                    ]],
                ]]],
            ]],
        ])
    }

    // MARK: - Spool

    func testSpooledPayloadSurvivesAProcessThatNeverExports() throws {
        // The launch that receives the payload writes it down and then dies.
        CrashSpool(directory: directory).write(payload())

        // The next one finds it.
        var exported: [SpanData] = []
        CrashReporter(directory: directory, sessionId: nil) { exported.append($0) }.drain()
        XCTAssertEqual(exported.count, 1)
        XCTAssertEqual(exported.first?.name, "crash")
    }

    func testDrainRemovesPayloadsSoACrashIsNotReportedEveryLaunch() throws {
        CrashSpool(directory: directory).write(payload())

        var exported: [SpanData] = []
        let reporter = CrashReporter(directory: directory, sessionId: nil) { exported.append($0) }
        reporter.drain()
        reporter.drain()
        XCTAssertEqual(exported.count, 1)
    }

    func testSpoolIsBoundedForAnAppCrashingOnLaunch() throws {
        let spool = CrashSpool(directory: directory)
        for _ in 0..<(CrashSpool.maxPayloads + 5) { spool.write(payload()) }
        XCTAssertEqual(spool.drain().count, CrashSpool.maxPayloads)
    }

    func testEmptyPayloadIsNotSpooled() throws {
        let spool = CrashSpool(directory: directory)
        spool.write(Data())
        XCTAssertEqual(spool.drain().count, 0)
    }

    // MARK: - Session join

    func testCrashSpanCarriesThePreviousRunsSession() throws {
        // Previous launch.
        LastSessionStore.configure(directory: directory)
        LastSessionStore.remember("sess_crashed")

        // This launch reads it before anything publishes a new one.
        LastSessionStore.resetForTesting()
        LastSessionStore.configure(directory: directory)
        let previous = LastSessionStore.previousSessionId
        XCTAssertEqual(previous, "sess_crashed")

        // A session rotating now must not retroactively claim the crash.
        LastSessionStore.remember("sess_live")
        XCTAssertEqual(LastSessionStore.previousSessionId, "sess_crashed")

        var exported: [SpanData] = []
        let reporter = CrashReporter(directory: directory, sessionId: previous) { exported.append($0) }
        reporter.ingest(payload: payload())
        XCTAssertEqual(exported.first?.attributes["session.id"], .string("sess_crashed"))
    }

    func testNoPreviousSessionIsNotAnError() throws {
        LastSessionStore.configure(directory: directory)
        XCTAssertNil(LastSessionStore.previousSessionId)

        var exported: [SpanData] = []
        CrashReporter(directory: directory, sessionId: nil) { exported.append($0) }.ingest(payload: payload())
        XCTAssertEqual(exported.count, 1)
        XCTAssertNil(exported.first?.attributes["session.id"])
    }
}
