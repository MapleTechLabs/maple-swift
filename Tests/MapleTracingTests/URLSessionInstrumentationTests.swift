import MapleCore
import XCTest
@testable import MapleTracing

/// Does the interception actually fire?
///
/// Every other test in this target asserts what the SDK *builds*. This one asserts what
/// leaves the process, through `URLSession.shared`, with the real swizzle installed —
/// which is the only thing that can catch "the header is correct and never sent". It
/// exists because that is exactly what happened: the first end-to-end run produced
/// perfect spans and not one `traceparent` on the wire.
final class URLSessionInstrumentationTests: XCTestCase {
    private static let target = URL(string: "https://backend.test/orders")!

    override func setUp() {
        super.setUp()
        SessionSink.shared.resetForTesting()
        RecordingProtocol.seen = []
        // The interceptor re-issues each request through its own session, which does not
        // see globally-registered protocols — so the stub goes there, not on the global
        // list, and what it records is genuinely what left the interceptor.
        MapleURLProtocol.relayProtocolClassesForTesting = [RecordingProtocol.self]

        var options = TracingOptions()
        options.ingestKey = "maple_pk_test"
        options.endpoint = URL(string: "https://ingest.maple.dev")!
        options.instrumentURLSession = .automatic
        options.instrumentViewControllers = false
        MapleTracing.shared.stop()
        MapleTracing.shared.start(options: options)
    }

    override func tearDown() {
        MapleTracing.shared.stop()
        MapleURLProtocol.relayProtocolClassesForTesting = []
        SessionSink.shared.resetForTesting()
        super.tearDown()
    }

    private func assertPropagated(_ line: UInt = #line) throws {
        let request = try XCTUnwrap(RecordingProtocol.seen.last, "no request reached the transport", line: line)
        let header = try XCTUnwrap(
            request.value(forHTTPHeaderField: "traceparent"),
            "traceparent was not injected — this URLSession API is not intercepted",
            line: line
        )
        XCTAssertNotNil(SpanContext.parse(traceParent: header), line: line)
    }

    func testCompletionHandlerAPIIsInstrumented() throws {
        let done = expectation(description: "request")
        URLSession.shared.dataTask(with: Self.target) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try assertPropagated()
    }

    func testRequestCompletionHandlerAPIIsInstrumented() throws {
        let done = expectation(description: "request")
        URLSession.shared.dataTask(with: URLRequest(url: Self.target)) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try assertPropagated()
    }

    func testDelegateStyleTaskIsInstrumented() throws {
        let task = URLSession.shared.dataTask(with: Self.target)
        task.resume()
        // No handler to wait on; the KVO observer is what closes the span.
        let done = expectation(description: "request")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done.fulfill() }
        wait(for: [done], timeout: 5)
        try assertPropagated()
    }

    /// The API most modern apps actually call.
    func testAsyncAwaitAPIIsInstrumented() async throws {
        _ = try? await URLSession.shared.data(from: Self.target)
        try assertPropagated()
    }

    func testSDKOwnRequestsAreNotTraced() {
        var request = URLRequest(url: URL(string: "https://ingest.maple.dev/v1/traces")!)
        request.setValue(MapleSDK.hint, forHTTPHeaderField: MapleSDK.hintHeader)
        XCTAssertFalse(MapleTracing.shared.shouldTrace(request))
    }
}

/// Answers every request locally and keeps the request it was given, headers included.
final class RecordingProtocol: URLProtocol {
    nonisolated(unsafe) static var seen: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "backend.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.append(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Parenting is a separate failure mode from propagation, and it fails silently: the
/// header is present and well-formed, it just names a trace nobody else is in. Two
/// requests inside one flow came back with two unrelated trace ids the first time this
/// went end to end.
final class ClientSpanParentingTests: XCTestCase {
    private static let target = URL(string: "https://backend.test/orders")!

    override func setUp() {
        super.setUp()
        RecordingProtocol.seen = []
        MapleURLProtocol.relayProtocolClassesForTesting = [RecordingProtocol.self]
        var options = TracingOptions()
        options.ingestKey = "maple_pk_test"
        options.endpoint = URL(string: "https://ingest.maple.dev")!
        options.instrumentURLSession = .automatic
        options.instrumentViewControllers = false
        MapleTracing.shared.stop()
        MapleTracing.shared.start(options: options)
    }

    override func tearDown() {
        MapleTracing.shared.stop()
        MapleURLProtocol.relayProtocolClassesForTesting = []
        super.tearDown()
    }

    private func sentTraceIds() -> [String] {
        RecordingProtocol.seen.compactMap { request -> String? in
            guard let header = request.value(forHTTPHeaderField: "traceparent"),
                  let context = SpanContext.parse(traceParent: header) else { return nil }
            return context.traceId.hex
        }
    }

    func testRequestsInsideOneSpanShareItsTrace() async throws {
        let traceId: String? = await MapleTracing.shared.span("checkout") { span in
            _ = try? await URLSession.shared.data(from: Self.target)
            _ = try? await URLSession.shared.data(from: Self.target.appendingPathComponent("submit"))
            return span?.traceId
        }
        let sent = sentTraceIds()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(Set(sent).count, 1, "both requests must be in one trace")
        XCTAssertEqual(sent.first, traceId, "and it must be the enclosing span's trace")
    }

    func testRequestOutsideAnySpanStartsItsOwnTrace() async throws {
        _ = try? await URLSession.shared.data(from: Self.target)
        XCTAssertEqual(sentTraceIds().count, 1)
    }
}
