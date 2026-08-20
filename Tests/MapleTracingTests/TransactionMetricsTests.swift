import XCTest

@testable import MapleTracing

/// A phase that did not happen must be absent, not zero.
///
/// This is the whole reason the type exists. A client span that is seconds longer than
/// the server span nested inside it says nothing about *why*; these attributes are what
/// turn that gap into "3.4s of it was a TLS handshake" or "3.4s of it was queueing". If a
/// reused connection reported `dns_ms = 0` instead of omitting it, every percentile over
/// DNS would be dragged toward zero by the requests that never resolved a name — and the
/// one number the attribute exists to produce would be the one number it gets wrong.
final class TransactionMetricsTests: XCTestCase {
    private var recorded: [SpanData] = []

    private func span() -> Span {
        let tracer = Tracer(options: TracingOptions()) { [weak self] data in self?.recorded.append(data) }
        return tracer.startSpan(name: "GET", kind: .client)
    }

    private func recordedAttributes(_ metrics: TransactionMetrics) -> [String: AttributeValue] {
        let span = span()
        metrics.apply(to: span)
        span.end()
        return recorded.last!.attributes
    }

    func testOmitsPhasesThatDidNotHappen() {
        var metrics = TransactionMetrics()
        metrics.reusedConnection = true
        metrics.ttfbMs = 42
        // A reused connection resolves no name and shakes no hands.
        metrics.dnsMs = nil
        metrics.tlsMs = nil

        let attributes = recordedAttributes(metrics)
        XCTAssertNil(attributes["maple.http.dns_ms"])
        XCTAssertNil(attributes["maple.http.tls_ms"])
        XCTAssertEqual(attributes["maple.http.ttfb_ms"], .double(42))
        XCTAssertEqual(attributes["maple.http.connection.reused"], .bool(true))
    }

    func testReportsEachPhaseUnderItsOwnKey() {
        var metrics = TransactionMetrics()
        metrics.totalMs = 1000
        metrics.queuedMs = 700
        metrics.dnsMs = 120
        metrics.connectMs = 400
        metrics.tlsMs = 250
        metrics.requestMs = 5
        metrics.ttfbMs = 200
        metrics.responseMs = 95
        metrics.alpn = "h2"

        let attributes = recordedAttributes(metrics)
        XCTAssertEqual(attributes["maple.http.total_ms"], .double(1000))
        XCTAssertEqual(attributes["maple.http.queued_ms"], .double(700))
        XCTAssertEqual(attributes["maple.http.dns_ms"], .double(120))
        XCTAssertEqual(attributes["maple.http.connect_ms"], .double(400))
        XCTAssertEqual(attributes["maple.http.tls_ms"], .double(250))
        XCTAssertEqual(attributes["maple.http.request_ms"], .double(5))
        XCTAssertEqual(attributes["maple.http.ttfb_ms"], .double(200))
        XCTAssertEqual(attributes["maple.http.response_ms"], .double(95))
        XCTAssertEqual(attributes["network.protocol.name"], .string("http"))
        XCTAssertEqual(attributes["network.protocol.version"], .string("2"))
    }

    /// A retried request is two connections, and summing a phase across them would
    /// invent a handshake that never took that long. Only the last transaction is
    /// reported; the count is what says the earlier ones existed — under semconv's own
    /// key, which is "required if and only if request was retried".
    func testResendCountUsesSemconvKeyAndIsOmittedWhenZero() {
        XCTAssertNil(recordedAttributes(TransactionMetrics())["http.request.resend_count"])

        var retried = TransactionMetrics()
        retried.resendCount = 2
        XCTAssertEqual(recordedAttributes(retried)["http.request.resend_count"], .int(2))
    }

    /// `h2` is an ALPN token, not a protocol family. Semconv wants `http` + `2`, and
    /// putting `h2` in `network.protocol.name` would hand every OTel consumer a value it
    /// reads as a different protocol entirely.
    func testALPNSplitsIntoSemconvNameAndVersion() {
        func split(_ alpn: String?) -> (name: String, version: String?)? {
            TransactionMetrics.protocol(fromALPN: alpn)
        }
        XCTAssertEqual(split("h2")?.name, "http")
        XCTAssertEqual(split("h2")?.version, "2")
        XCTAssertEqual(split("http/1.1")?.version, "1.1")
        XCTAssertEqual(split("h3")?.version, "3")
        XCTAssertEqual(split("h3-29")?.version, "3")
        XCTAssertNil(split(nil))
        XCTAssertNil(split(""))
        // Unrecognized: recorded, but no version invented for it.
        XCTAssertEqual(split("spdy/3.1")?.name, "spdy/3.1")
        XCTAssertNil(split("spdy/3.1")?.version)
    }

    func testElapsedRejectsMissingAndNegativeIntervals() {
        let start = Date(timeIntervalSince1970: 1000)
        let end = Date(timeIntervalSince1970: 1000.25)

        XCTAssertEqual(TransactionMetrics.elapsed(start, end), 250)
        XCTAssertNil(TransactionMetrics.elapsed(nil, end))
        XCTAssertNil(TransactionMetrics.elapsed(start, nil))
        // Defensive: the dates are independent optionals with no documented ordering
        // guarantee, and a negative duration would read as a very fast request.
        XCTAssertNil(TransactionMetrics.elapsed(end, start))
    }
}
