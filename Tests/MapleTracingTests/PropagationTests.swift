import MapleCore
import XCTest
@testable import MapleTracing

/// Propagation is the feature. A span that does not reach the backend as a *parent* is a
/// mobile trace and a server trace that merely happened at the same time.
final class PropagationTests: XCTestCase {
    private var recorded: [SpanData] = []

    override func setUp() {
        super.setUp()
        recorded = []
        SessionSink.shared.resetForTesting()
    }

    override func tearDown() {
        SessionSink.shared.resetForTesting()
        super.tearDown()
    }

    private func makeHooks(
        options: TracingOptions = TracingOptions(),
        propagate: @escaping (URLRequest) -> Bool = { _ in true }
    ) -> URLSessionInstrumentation.Hooks {
        let tracer = Tracer(options: options) { [weak self] data in self?.recorded.append(data) }
        return URLSessionInstrumentation.Hooks(
            tracer: tracer,
            shouldTrace: { _ in true },
            shouldPropagate: propagate
        )
    }

    func testTraceparentIsInjectedAndMatchesTheSpan() throws {
        let hooks = makeHooks()
        let (outgoing, started) = URLSessionInstrumentation.begin(
            URLRequest(url: URL(string: "https://api.acme.com/orders")!),
            hooks: hooks
        )
        let span = try XCTUnwrap(started)
        let header = try XCTUnwrap(outgoing.value(forHTTPHeaderField: "traceparent"))

        let parsed = try XCTUnwrap(SpanContext.parse(traceParent: header))
        XCTAssertEqual(parsed.traceId.hex, span.traceId)
        // The backend's server span parents itself to *this* span id. If the header
        // carried anything else the two halves would not join.
        XCTAssertEqual(parsed.spanId.hex, span.spanId)
    }

    func testHeaderIsAbsentWhenTargetIsNotAllowed() {
        let hooks = makeHooks(propagate: { _ in false })
        let (outgoing, span) = URLSessionInstrumentation.begin(
            URLRequest(url: URL(string: "https://payments.example.com/charge")!),
            hooks: hooks
        )
        XCTAssertNotNil(span, "the request is still traced — only the header is withheld")
        XCTAssertNil(outgoing.value(forHTTPHeaderField: "traceparent"))
    }

    func testClientAttributes() throws {
        let hooks = makeHooks()
        var request = URLRequest(url: URL(string: "https://api.acme.com:8443/orders?q=1")!)
        request.httpMethod = "POST"
        let (_, span) = URLSessionInstrumentation.begin(request, hooks: hooks)
        try XCTUnwrap(span).end()

        let data = try XCTUnwrap(recorded.first)
        XCTAssertEqual(data.name, "POST")  // method alone, per OTel — not one operation per URL
        XCTAssertEqual(data.kind, .client)
        XCTAssertEqual(data.attributes["http.request.method"], .string("POST"))
        XCTAssertEqual(data.attributes["server.address"], .string("api.acme.com"))
        XCTAssertEqual(data.attributes["server.port"], .int(8443))
    }

    func testCredentialsAreStrippedFromRecordedURLs() throws {
        let hooks = makeHooks()
        let (_, span) = URLSessionInstrumentation.begin(
            URLRequest(url: URL(string: "https://user:hunter2@api.acme.com/orders")!),
            hooks: hooks
        )
        try XCTUnwrap(span).end()

        let full = try XCTUnwrap(recorded.first?.attributes["url.full"])
        guard case .string(let value) = full else { return XCTFail("expected a string") }
        XCTAssertFalse(value.contains("hunter2"))
        XCTAssertTrue(value.contains("api.acme.com/orders"))
    }

    func testSpanCarriesTheLiveSessionId() throws {
        SessionSink.shared.publish(sessionId: "sess-1")
        let hooks = makeHooks()
        let (_, started) = URLSessionInstrumentation.begin(
            URLRequest(url: URL(string: "https://api.acme.com/orders")!),
            hooks: hooks
        )
        let span = try XCTUnwrap(started)
        span.end()

        // Both directions of the join, from one span start.
        XCTAssertEqual(recorded.first?.attributes["session.id"], .string("sess-1"))
        XCTAssertEqual(SessionSink.shared.observedTraceIds(for: "sess-1"), [span.traceId])
    }

    func testSpansAreParentedToTheActiveSpan() throws {
        let tracer = Tracer(options: TracingOptions()) { [weak self] data in self?.recorded.append(data) }
        let parent = tracer.startSpan(name: "checkout")
        TraceContext.withSpan(parent) {
            let child = tracer.startSpan(name: "GET", kind: .client)
            XCTAssertEqual(child.traceId, parent.traceId)
            XCTAssertEqual(child.parentSpanId?.hex, parent.spanId)
            child.end()
        }
        parent.end()
    }

    // MARK: - Targeting

    private func tracingTargets(_ targets: [String]?, url: String) -> Bool {
        var options = TracingOptions()
        options.ingestKey = "maple_pk_test"
        options.endpoint = URL(string: "https://ingest.maple.dev")!
        options.tracePropagationTargets = targets
        options.instrumentURLSession = .off
        options.instrumentViewControllers = false

        // `shouldPropagate` reads the live options, so this exercises the real path
        // rather than a copy of the rule.
        MapleTracing.shared.stop()
        MapleTracing.shared.start(options: options)
        defer { MapleTracing.shared.stop() }
        return MapleTracing.shared.shouldPropagate(URLRequest(url: URL(string: url)!))
    }

    func testDefaultTargetsPropagateEverywhereExceptIngest() {
        XCTAssertTrue(tracingTargets(nil, url: "https://api.acme.com/orders"))
        // Without this the exporter traces its own exports: one batch produces a span,
        // that span produces a batch, forever.
        XCTAssertFalse(tracingTargets(nil, url: "https://ingest.maple.dev/v1/traces"))
        XCTAssertFalse(tracingTargets(nil, url: "https://ingest.maple.dev/v1/sessionEvents"))
    }

    func testOnlyTheIngestPathsAreExcludedNotTheWholeHost() {
        // A self-hosted deployment can put the API and the gateway behind one host.
        // Excluding the origin would silently untrace that app's entire network layer.
        XCTAssertTrue(tracingTargets(nil, url: "https://ingest.maple.dev/v2/services"))
    }

    func testExplicitTargetsNarrowPropagation() {
        XCTAssertTrue(tracingTargets(["api.acme.com"], url: "https://api.acme.com/orders"))
        XCTAssertFalse(tracingTargets(["api.acme.com"], url: "https://payments.example.com/charge"))
        XCTAssertTrue(tracingTargets(["\\.acme\\.com"], url: "https://cdn.acme.com/logo.png"))
    }
}
