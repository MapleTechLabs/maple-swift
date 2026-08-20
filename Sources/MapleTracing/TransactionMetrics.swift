import Foundation

/// The phase breakdown `URLSessionTaskMetrics` knows and a span otherwise throws away.
///
/// A client span measures one number: `resume()` to completion. When that number is much
/// larger than the server span nested inside it — which is the normal case on a phone —
/// nothing in the trace says which part of the gap is DNS, which is a TLS handshake on a
/// cold connection, which is the request sitting in a queue, and which is body transfer.
/// Every answer to "the app is slow but the API is fast" starts by guessing.
///
/// `URLSession` has measured all of it the whole time and hands it over in
/// `didFinishCollecting`. This turns that into span attributes.
///
/// Only the **last** transaction is reported. A task with several transactions redirected
/// or was retried, and the last one is the one that produced the bytes the caller saw;
/// `resend_count` is what says the earlier ones happened, so no phase is silently summed
/// across two different connections.
struct TransactionMetrics {
    /// Wall clock from the task being handed to `URLSession` to the last byte.
    var totalMs: Double?
    /// `fetchStart` → `requestStart`: the request existed but had not gone out yet.
    /// Connection setup lands here, and so does waiting for a free connection.
    var queuedMs: Double?
    var dnsMs: Double?
    /// TCP, including the TLS handshake nested inside it.
    var connectMs: Double?
    var tlsMs: Double?
    var requestMs: Double?
    /// Request sent → first byte back. The closest client-side analogue of server time.
    var ttfbMs: Double?
    /// First byte → last byte: body transfer, the part that scales with payload size.
    var responseMs: Double?
    /// False means this request paid for a new connection.
    var reusedConnection: Bool?
    var proxyConnection: Bool?
    /// The negotiated ALPN identifier as `URLSession` reports it — `http/1.1`, `h2`,
    /// `h3`. Split into semconv's `network.protocol.name` + `.version` on the way out; a
    /// stall that only happens on one of them names itself.
    var alpn: String?
    /// Transactions beyond the first. OTel counts a redirect as a resend just like a
    /// retry ("cause doesn't matter"), and every one of them is its own transaction, so
    /// this single count is the whole story and `redirectCount` would double-report it.
    var resendCount: Int = 0

    /// `URLSessionTaskMetrics` has no public initializer and its transactions can only be
    /// produced by a live `URLSession`, so the phase math and the attribute contract are
    /// reachable from a test only through this.
    init() {}

    init(_ metrics: URLSessionTaskMetrics) {
        resendCount = max(0, metrics.transactionMetrics.count - 1)

        guard let last = metrics.transactionMetrics.last else { return }

        reusedConnection = last.isReusedConnection
        proxyConnection = last.isProxyConnection
        alpn = last.networkProtocolName

        totalMs = Self.elapsed(last.fetchStartDate, last.responseEndDate)
        queuedMs = Self.elapsed(last.fetchStartDate, last.requestStartDate)
        dnsMs = Self.elapsed(last.domainLookupStartDate, last.domainLookupEndDate)
        connectMs = Self.elapsed(last.connectStartDate, last.connectEndDate)
        tlsMs = Self.elapsed(last.secureConnectionStartDate, last.secureConnectionEndDate)
        requestMs = Self.elapsed(last.requestStartDate, last.requestEndDate)
        ttfbMs = Self.elapsed(last.requestEndDate, last.responseStartDate)
        responseMs = Self.elapsed(last.responseStartDate, last.responseEndDate)
    }

    /// Every date on `URLSessionTaskTransactionMetrics` is optional, and a reused
    /// connection legitimately has no DNS or TLS dates at all. A missing phase is
    /// absent, never zero: zero would read as "DNS was instant" in a percentile.
    static func elapsed(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end else { return nil }
        let ms = end.timeIntervalSince(start) * 1000
        return ms >= 0 ? ms : nil
    }

    /// Phase timings go under the `maple.*` vendor namespace because OTel has no
    /// standard for a per-request connection breakdown on a span. Everything OTel *does*
    /// spell — the resend count, the negotiated protocol — uses the semconv key verbatim,
    /// so a Maple span stays readable by any OTel-aware consumer.
    func apply(to span: Span) {
        if let (name, version) = Self.protocol(fromALPN: alpn) {
            span.setAttribute("network.protocol.name", name)
            if let version { span.setAttribute("network.protocol.version", version) }
        }
        set(span, "maple.http.total_ms", totalMs)
        set(span, "maple.http.queued_ms", queuedMs)
        set(span, "maple.http.dns_ms", dnsMs)
        set(span, "maple.http.connect_ms", connectMs)
        set(span, "maple.http.tls_ms", tlsMs)
        set(span, "maple.http.request_ms", requestMs)
        set(span, "maple.http.ttfb_ms", ttfbMs)
        set(span, "maple.http.response_ms", responseMs)
        if let reusedConnection { span.setAttribute("maple.http.connection.reused", reusedConnection) }
        if let proxyConnection, proxyConnection { span.setAttribute("maple.http.connection.proxy", true) }
        // Semconv: "Required if and only if request was retried."
        if resendCount > 0 { span.setAttribute("http.request.resend_count", resendCount) }
    }

    /// ALPN identifier → semconv `network.protocol.name` + `.version`.
    ///
    /// `URLSession` reports what was negotiated on the wire (`h2`), but semconv wants the
    /// application-layer protocol lowercase-normalized (`http`) with the post-negotiation
    /// version beside it (`2`). Emitting `h2` as the *name* would put an ALPN token in a
    /// field every OTel consumer reads as a protocol family — and `h2` vs `http/1.1` is
    /// exactly the distinction worth querying here, so it belongs in `.version`.
    static func `protocol`(fromALPN alpn: String?) -> (name: String, version: String?)? {
        guard let alpn, !alpn.isEmpty else { return nil }
        switch alpn.lowercased() {
        case "http/0.9": return ("http", "0.9")
        case "http/1.0": return ("http", "1.0")
        case "http/1.1": return ("http", "1.1")
        case "h2", "h2c": return ("http", "2")
        // Drafts still appear in the field: `h3-29`, `h3-Q050`.
        case let value where value == "h3" || value.hasPrefix("h3-"): return ("http", "3")
        // Something unrecognized is still worth recording, but guessing a version for it
        // would be inventing data.
        case let value: return (value, nil)
        }
    }

    private func set(_ span: Span, _ key: String, _ value: Double?) {
        guard let value else { return }
        span.setAttribute(key, .double((value * 1000).rounded() / 1000))
    }
}
