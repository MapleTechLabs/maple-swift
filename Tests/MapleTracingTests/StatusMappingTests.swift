import MapleCore
import XCTest
@testable import MapleTracing

/// 4xx is not an error.
///
/// OTel's client-span guidance says otherwise, but Maple's own gateway already applies
/// this rule to its server spans (`otel_status_for_rejection`) precisely so error
/// dashboards are not flooded by expected 401/402/429s. A platform where the two ends
/// disagree produces a trace that is half red for no reason.
final class StatusMappingTests: XCTestCase {
    private var recorded: [SpanData] = []
    private var events: [SessionEventDraft] = []

    override func setUp() {
        super.setUp()
        recorded = []
        events = []
        SessionSink.shared.resetForTesting()
        SessionSink.shared.publish(sessionId: "sess-status")
        SessionSink.shared.setEventRelay { [weak self] draft in self?.events.append(draft) }
    }

    override func tearDown() {
        SessionSink.shared.resetForTesting()
        super.tearDown()
    }

    private let url = URL(string: "https://api.acme.com/orders")!

    private func finish(status: Int?, error: Error? = nil) -> SpanData {
        let tracer = Tracer(options: TracingOptions()) { [weak self] data in self?.recorded.append(data) }
        let request = URLRequest(url: url)
        let span = tracer.startSpan(name: "GET", kind: .client)
        let response = status.map {
            HTTPURLResponse(url: url, statusCode: $0, httpVersion: nil, headerFields: nil)!
        }
        URLSessionInstrumentation.finish(span: span, response: response, error: error, request: request)
        return recorded.last!
    }

    func test2xxIsOk() {
        XCTAssertEqual(finish(status: 200).status, .ok)
    }

    func test4xxIsOkNotError() {
        XCTAssertEqual(finish(status: 404).status, .ok)
        XCTAssertEqual(finish(status: 401).status, .ok)
        XCTAssertEqual(finish(status: 429).status, .ok)
    }

    func test5xxIsError() {
        guard case .error(let message) = finish(status: 503).status else {
            return XCTFail("5xx must be an Error")
        }
        XCTAssertEqual(message, "HTTP 503")
    }

    func testTransportFailureIsError() {
        let failure = URLError(.notConnectedToInternet)
        let data = finish(status: nil, error: failure)
        guard case .error = data.status else { return XCTFail("a transport failure must be an Error") }
        XCTAssertNil(data.attributes["http.response.status_code"])
    }

    func testStatusCodeIsRecordedRegardless() {
        XCTAssertEqual(finish(status: 404).attributes["http.response.status_code"], .int(404))
    }

    func testFailuresBumpTheSessionErrorCount() {
        _ = finish(status: 200)
        XCTAssertEqual(SessionSink.shared.counters(for: "sess-status").errorCount, 0)
        _ = finish(status: 404)
        // A 404 is not an error *span*, and it is not a session error either — the
        // session-list filter would otherwise flag every app that 404s a cache probe.
        XCTAssertEqual(SessionSink.shared.counters(for: "sess-status").errorCount, 0)
        _ = finish(status: 500)
        XCTAssertEqual(SessionSink.shared.counters(for: "sess-status").errorCount, 1)
    }

    func testEachRequestEmitsANetworkSessionEvent() throws {
        let span = finish(status: 201)
        let event = try XCTUnwrap(events.last)
        XCTAssertEqual(event.kind, .network)
        XCTAssertEqual(event.netStatus, 201)
        XCTAssertEqual(event.netMethod, "GET")
        XCTAssertEqual(event.netUrl, "https://api.acme.com/orders")
        // Carried explicitly, not resolved from the ambient context: this row is built on
        // a network callback thread where there is no ambient span, so asking for "the
        // active trace" there answered nothing and every network row shipped a blank
        // `TraceId` — the column the transcript uses to reach the waterfall.
        XCTAssertEqual(event.traceId, span.context.traceId.hex)
    }

    func testSpanEndIsIdempotent() {
        let tracer = Tracer(options: TracingOptions()) { [weak self] data in self?.recorded.append(data) }
        let span = tracer.startSpan(name: "GET")
        span.end()
        span.end()
        // A URLSession task can report completion through both a delegate and a handler;
        // a double-ended span would export twice under one span id.
        XCTAssertEqual(recorded.count, 1)
    }
}
