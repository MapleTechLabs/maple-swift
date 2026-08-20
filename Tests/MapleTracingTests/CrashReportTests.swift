import XCTest
@testable import MapleTracing

/// The whole crash path from a MetricKit payload to an encoded span, driven by fixtures.
///
/// `MXCrashDiagnostic` has no public initialiser, so a test can never build one. Parsing
/// the payload's JSON instead is what makes everything below the `MetricKit` boundary
/// reachable from a unit test.
final class CrashReportTests: XCTestCase {
    /// The shape `MXDiagnosticPayload.jsonRepresentation()` produces.
    ///
    /// `callStackRootFrames` is deliberately the *base* of the stack: `main` calls
    /// `applicationDidFinishLaunching` calls `loadOrders`, and `loadOrders` is where it
    /// died.
    private func payload(
        exceptionType: Int = 1,
        signal: Int = 11,
        terminationReason: String = "Namespace SIGNAL, Code 0xb",
        appVersion: String = "1.4.2",
        leafBinary: String = "MyApp",
        leafOffset: Int = 119024
    ) -> Data {
        let json: [String: Any] = [
            "timeStampBegin": "2026-08-19 12:00:00 +0000",
            "timeStampEnd": "2026-08-20 09:30:00 +0000",
            "crashDiagnostics": [[
                "version": "1.0.0",
                "diagnosticMetaData": [
                    "appVersion": appVersion,
                    "appBuildVersion": "318",
                    "osVersion": "iPhone OS 18.0 (22A123)",
                    "deviceType": "iPhone17,1",
                    "platformArchitecture": "arm64e",
                    "exceptionType": exceptionType,
                    "exceptionCode": 0,
                    "signal": signal,
                    "terminationReason": terminationReason,
                    "virtualMemoryRegionInfo": "0x0000000000000010 is not in any region",
                ],
                "callStackTree": [
                    "callStackPerThread": true,
                    "callStacks": [[
                        "threadAttributed": true,
                        "callStackRootFrames": [[
                            "binaryUUID": "11111111-1111-1111-1111-111111111111",
                            "binaryName": "libdyld.dylib",
                            "address": 7_000_000_000,
                            "offsetIntoBinaryTextSegment": 4096,
                            "subFrames": [[
                                "binaryUUID": "22222222-2222-2222-2222-222222222222",
                                "binaryName": "MyApp",
                                "address": 4_363_151_360,
                                "offsetIntoBinaryTextSegment": 41234,
                                "subFrames": [[
                                    "binaryUUID": "22222222-2222-2222-2222-222222222222",
                                    "binaryName": leafBinary,
                                    "address": 4_363_200_000,
                                    "offsetIntoBinaryTextSegment": leafOffset,
                                ]],
                            ]],
                        ]],
                    ]],
                ],
            ]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func onlyReport(_ data: Data) throws -> CrashReport {
        let reports = CrashReportParser.reports(fromPayload: data)
        XCTAssertEqual(reports.count, 1)
        return try XCTUnwrap(reports.first)
    }

    // MARK: - Parsing

    func testParsesMetadata() throws {
        let report = try onlyReport(payload())
        XCTAssertEqual(report.exceptionType, "EXC_BAD_ACCESS")
        XCTAssertEqual(report.signal, "SIGSEGV")
        XCTAssertEqual(report.appVersion, "1.4.2")
        XCTAssertEqual(report.appBuildVersion, "318")
        XCTAssertEqual(report.deviceType, "iPhone17,1")
        XCTAssertEqual(report.timestamp, Date(timeIntervalSince1970: 1_787_218_200))
    }

    func testMessageCarriesSignalAndTerminationReason() throws {
        let report = try onlyReport(payload())
        XCTAssertEqual(report.message, "EXC_BAD_ACCESS (SIGSEGV): Namespace SIGNAL, Code 0xb")
    }

    func testUnknownExceptionTypeFallsBackToSignalThenCrash() throws {
        XCTAssertEqual(try onlyReport(payload(exceptionType: 99)).exceptionType, "SIGSEGV")
        XCTAssertEqual(try onlyReport(payload(exceptionType: 99, signal: 99)).exceptionType, "Crash")
    }

    func testEmptyPayloadYieldsNothing() {
        XCTAssertEqual(CrashReportParser.reports(fromPayload: Data()).count, 0)
        XCTAssertEqual(CrashReportParser.reports(fromPayload: Data("{}".utf8)).count, 0)
    }

    // MARK: - Stack ordering

    func testFramesAreInnermostFirst() throws {
        let report = try onlyReport(payload())
        // The tree arrives base-first. Reading it in that order would put `libdyld` at
        // the top of every stack in the app and collapse every issue into one.
        XCTAssertEqual(report.frames.map(\.binaryName), ["MyApp", "MyApp", "libdyld.dylib"])
        XCTAssertEqual(report.frames.first?.offset, 119024)
    }

    func testStacktraceIsIndexedApplStyle() throws {
        let lines = try onlyReport(payload()).stacktrace.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("0   MyApp   0x"), lines[0])
        XCTAssertTrue(lines[2].hasPrefix("2   libdyld.dylib   0x"), lines[2])
    }

    func testOffsetsAreHexSoRedactionErasesThem() throws {
        // Load bearing: Maple's fingerprint strips `0x…` from a frame before hashing.
        // A decimal offset would survive and re-split every issue on every rebuild,
        // because an offset moves with any code change.
        let stack = try onlyReport(payload()).stacktrace
        XCTAssertTrue(stack.contains("+0x1d0f0"), stack)
        XCTAssertFalse(stack.contains("119024"), stack)
    }

    func testBinaryImagesArePairedAndDeduplicated() throws {
        let report = try onlyReport(payload())
        XCTAssertEqual(report.binaryImages, [
            "MyApp=22222222-2222-2222-2222-222222222222",
            "libdyld.dylib=11111111-1111-1111-1111-111111111111",
        ])
    }

    // MARK: - Span shape

    func testSpanCarriesBothHalvesOfTheErrorContract() throws {
        let span = CrashSpanBuilder.span(for: try onlyReport(payload()), sessionId: "sess_1")
        // Status Error AND an `exception` event. Either alone produces no error row.
        guard case .error(let message) = span.status else { return XCTFail("expected Error status") }
        XCTAssertEqual(message, "EXC_BAD_ACCESS (SIGSEGV): Namespace SIGNAL, Code 0xb")

        let event = try XCTUnwrap(span.events.first)
        XCTAssertEqual(event.name, "exception")
        XCTAssertEqual(event.attributes["exception.type"], .string("EXC_BAD_ACCESS"))
        XCTAssertNotNil(event.attributes["exception.stacktrace"])
    }

    func testSpanIsInstantaneous() throws {
        let span = CrashSpanBuilder.span(for: try onlyReport(payload()), sessionId: nil)
        XCTAssertEqual(span.startTime, span.endTime)
    }

    func testSpanCarriesTheSessionForTheReplayJoin() throws {
        let span = CrashSpanBuilder.span(for: try onlyReport(payload()), sessionId: "sess_1")
        XCTAssertEqual(span.attributes["session.id"], .string("sess_1"))
        XCTAssertNil(CrashSpanBuilder.span(for: try onlyReport(payload()), sessionId: nil).attributes["session.id"])
    }

    func testSpanReportsTheCrashedVersionNotTheRunningOne() throws {
        let span = CrashSpanBuilder.span(for: try onlyReport(payload(appVersion: "1.4.2")), sessionId: nil)
        XCTAssertEqual(span.resourceOverrides["service.version"], .string("1.4.2+318"))
    }

    /// Two crashes at different sites in the same binary must not be one issue, and the
    /// same crash on two builds must not be two.
    func testRenderedStacksDistinguishSitesButNotBuilds() throws {
        let siteA = try onlyReport(payload(leafOffset: 119_024)).stacktrace
        let siteB = try onlyReport(payload(leafBinary: "UIKitCore", leafOffset: 500)).stacktrace
        XCTAssertNotEqual(siteA, siteB)

        // Same site, rebuilt: offsets shift, binary names do not — and only the names
        // survive Maple's frame redaction.
        let rebuilt = try onlyReport(payload(leafOffset: 119_999)).stacktrace
        XCTAssertNotEqual(siteA, rebuilt)
        XCTAssertEqual(redacted(siteA), redacted(rebuilt))
        XCTAssertNotEqual(redacted(siteA), redacted(siteB))
    }

    /// Mirrors Maple's `FRAME_REDACTIONS` for the tokens an iOS frame can contain.
    private func redacted(_ stack: String) -> String {
        stack.replacingOccurrences(
            of: ":[0-9]+|line [0-9]+|0x[0-9a-fA-F]+|[0-9a-fA-F]{8,}|[0-9]{6,}",
            with: "",
            options: .regularExpression
        )
    }
}
