import MapleCore
import XCTest

/// The pipeline seam.
///
/// Worth testing precisely because its failure mode is the quietest one in the SDK: an
/// unconfigured key means 401 on every request, and every transport here swallows a 401
/// by design. A misconfigured pipeline should be a log line at start-up, not silence for
/// a whole TestFlight cycle.
final class BundleConfigurationTests: XCTestCase {
    /// Stands in for a built app's Info.plist.
    private final class StubBundle: Bundle, @unchecked Sendable {
        var values: [String: Any] = [:]
        override func object(forInfoDictionaryKey key: String) -> Any? { values[key] }
    }

    private func read(_ values: [String: Any]) -> MapleBundleConfiguration {
        let bundle = StubBundle()
        bundle.values = values
        return MapleBundleConfiguration.read(from: bundle)
    }

    func testNestedDictionary() {
        let configuration = read(["Maple": [
            "IngestKey": "maple_pk_abc",
            "Endpoint": "https://ingest.example.com",
            "Environment": "staging",
            "ServiceName": "acme-ios",
            "TracesSampleRate": 0.25,
        ]])
        XCTAssertEqual(configuration.ingestKey, "maple_pk_abc")
        XCTAssertEqual(configuration.endpoint?.absoluteString, "https://ingest.example.com")
        XCTAssertEqual(configuration.environment, "staging")
        XCTAssertEqual(configuration.serviceName, "acme-ios")
        XCTAssertEqual(configuration.tracesSampleRate, 0.25)
    }

    /// The shape a pipeline gets for free: `INFOPLIST_KEY_MapleIngestKey`, no plist file.
    func testFlatKeys() {
        let configuration = read([
            "MapleIngestKey": "maple_pk_flat",
            "MapleEnvironment": "production",
        ])
        XCTAssertEqual(configuration.ingestKey, "maple_pk_flat")
        XCTAssertEqual(configuration.environment, "production")
    }

    func testNestedWinsOverFlat() {
        let configuration = read([
            "MapleIngestKey": "maple_pk_flat",
            "Maple": ["IngestKey": "maple_pk_nested"],
        ])
        XCTAssertEqual(configuration.ingestKey, "maple_pk_nested")
    }

    /// Xcode leaves the token verbatim when no such build setting exists. Reading it as a
    /// key would send `Bearer $(MAPLE_INGEST_KEY)` and earn a 401 nothing surfaces.
    func testUnsubstitutedBuildSettingIsRejected() {
        XCTAssertNil(read(["MapleIngestKey": "$(MAPLE_INGEST_KEY)"]).ingestKey)
        XCTAssertNil(read(["MapleIngestKey": "${MAPLE_INGEST_KEY}"]).ingestKey)
    }

    func testEmptyAndWhitespaceAreNotValues() {
        XCTAssertNil(read(["MapleIngestKey": ""]).ingestKey)
        XCTAssertNil(read(["MapleIngestKey": "   "]).ingestKey)
    }

    func testValuesAreTrimmed() {
        // A build setting written across a line continuation picks up whitespace, and a
        // bearer token with a trailing newline is a 401.
        XCTAssertEqual(read(["MapleIngestKey": "  maple_pk_abc\n"]).ingestKey, "maple_pk_abc")
    }

    func testSampleRateAsString() {
        // A build setting substituted into a plist is always a string, never a number.
        XCTAssertEqual(read(["MapleTracesSampleRate": "0.1"]).tracesSampleRate, 0.1)
        XCTAssertNil(read(["MapleTracesSampleRate": "nope"]).tracesSampleRate)
    }

    func testMalformedEndpointIsIgnoredNotFatal() {
        XCTAssertNil(read(["MapleEndpoint": "not a url"]).endpoint)
    }

    func testAbsentConfigurationIsEmptyNotAnError() {
        let configuration = read([:])
        XCTAssertNil(configuration.ingestKey)
        XCTAssertNil(configuration.endpoint)
    }
}
