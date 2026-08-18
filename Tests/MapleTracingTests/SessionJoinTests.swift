import MapleCore
import XCTest
@testable import MapleTracing

/// The sink is what makes a trace resolvable to a recording. Everything here is about one
/// failure: a session's `trace_ids` containing traces that did not happen in it.
final class SessionJoinTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SessionSink.shared.resetForTesting()
    }

    override func tearDown() {
        SessionSink.shared.resetForTesting()
        super.tearDown()
    }

    func testTraceIdsAreDedupedAndOrdered() {
        SessionSink.shared.publish(sessionId: "a")
        SessionSink.shared.recordTraceId("t1")
        SessionSink.shared.recordTraceId("t2")
        SessionSink.shared.recordTraceId("t1")
        XCTAssertEqual(SessionSink.shared.observedTraceIds(for: "a"), ["t1", "t2"])
    }

    func testTraceIdsAreCappedDroppingOldest() {
        SessionSink.shared.publish(sessionId: "a")
        let overflow = SessionSink.maxTraceIdsPerSession + 10
        for index in 0..<overflow {
            SessionSink.shared.recordTraceId("t\(index)")
        }
        let ids = SessionSink.shared.observedTraceIds(for: "a")
        XCTAssertEqual(ids.count, SessionSink.maxTraceIdsPerSession)
        // The tail is what someone is looking at; the head is what goes.
        XCTAssertEqual(ids.last, "t\(overflow - 1)")
        XCTAssertFalse(ids.contains("t0"))
    }

    func testRotationDoesNotSpillTraceIdsOntoTheNewSession() {
        // iOS rotates the session on every foreground transition. A leak here attributes
        // a recording to traces it never produced.
        SessionSink.shared.publish(sessionId: "old")
        SessionSink.shared.recordTraceId("t-old")
        SessionSink.shared.publish(sessionId: "new")
        SessionSink.shared.recordTraceId("t-new")

        XCTAssertEqual(SessionSink.shared.observedTraceIds(for: "old"), ["t-old"])
        XCTAssertEqual(SessionSink.shared.observedTraceIds(for: "new"), ["t-new"])
    }

    func testTraceIdsWithNoSessionAreDropped() {
        // Not parked for a later session: a span created before recording starts belongs
        // to no recording, and a later one must not inherit it.
        SessionSink.shared.recordTraceId("orphan")
        SessionSink.shared.publish(sessionId: "a")
        XCTAssertEqual(SessionSink.shared.observedTraceIds(for: "a"), [])
    }

    func testDiscardForgetsTheSession() {
        SessionSink.shared.publish(sessionId: "a")
        SessionSink.shared.recordTraceId("t1")
        SessionSink.shared.discard(sessionId: "a")
        XCTAssertEqual(SessionSink.shared.observedTraceIds(for: "a"), [])
        XCTAssertNil(SessionSink.shared.currentSessionId)
    }

    func testCounters() {
        SessionSink.shared.publish(sessionId: "a")
        SessionSink.shared.recordClick()
        SessionSink.shared.recordClick()
        SessionSink.shared.recordPageView()
        SessionSink.shared.recordError()
        let counters = SessionSink.shared.counters(for: "a")
        XCTAssertEqual(counters.clickCount, 2)
        XCTAssertEqual(counters.pageViews, 1)
        XCTAssertEqual(counters.errorCount, 1)
    }

    func testActiveTraceIdComesFromTheTracer() {
        var recorded: [SpanData] = []
        let tracer = Tracer(options: TracingOptions()) { recorded.append($0) }
        SessionSink.shared.setActiveTraceIdProvider { TraceContext.activeTraceId }

        XCTAssertNil(SessionSink.shared.activeTraceId)
        let span = tracer.startSpan(name: "checkout")
        TraceContext.withSpan(span) {
            // This is what stamps `session_events.TraceId`, and it is the link the
            // transcript uses to jump from an event to its waterfall.
            XCTAssertEqual(SessionSink.shared.activeTraceId, span.traceId)
        }
        XCTAssertNil(SessionSink.shared.activeTraceId)
        span.end()
        XCTAssertEqual(recorded.count, 1)
    }

    func testUnsampledSpansAreNotExportedButStillCount() {
        var recorded: [SpanData] = []
        var options = TracingOptions()
        options.tracesSampleRate = 0
        let tracer = Tracer(options: options) { recorded.append($0) }
        SessionSink.shared.publish(sessionId: "a")

        let span = tracer.startSpan(name: "GET")
        span.end()

        XCTAssertTrue(recorded.isEmpty)
        XCTAssertFalse(span.context.sampled)
        // The session still knows a trace happened, which is what keeps a sampled-out
        // request visible in the transcript.
        XCTAssertEqual(SessionSink.shared.observedTraceIds(for: "a"), [span.traceId])
    }
}
