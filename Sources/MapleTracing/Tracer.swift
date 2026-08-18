import Foundation
import MapleCore

/// Creates spans, and is the single place a span becomes joined to a session.
///
/// The join is two calls made on every span start, both mirroring the browser SDK's
/// `TraceIdCollector.onStart`:
///
///  * `SessionSink.recordTraceId` — feeds `session_replays.TraceIds` on the `ended`
///    metadata row, which is what the UI searches to answer "which recording produced
///    this trace".
///  * a `session.id` **span attribute** — the reverse direction, and a span attribute
///    rather than a resource attribute because sessions rotate under a fixed resource.
public final class Tracer: @unchecked Sendable {
    private let options: TracingOptions
    private let onSpanEnd: (SpanData) -> Void

    init(options: TracingOptions, onSpanEnd: @escaping (SpanData) -> Void) {
        self.options = options
        self.onSpanEnd = onSpanEnd
    }

    /// Start a span, parented to `parent` or to whatever is active.
    ///
    /// `remoteParent` is for a context arriving over the wire; nothing on iOS produces one
    /// today, but the signature is where it would go and leaving it out would make
    /// inbound continuation a refactor rather than a call.
    public func startSpan(
        name: String,
        kind: SpanKind = .internal,
        parent: Span? = nil,
        remoteParent: SpanContext? = nil,
        attributes: [String: AttributeValue] = [:],
        startTime: Date = Date()
    ) -> Span {
        let parentContext = remoteParent ?? (parent ?? TraceContext.current)?.context

        let traceId = parentContext?.traceId ?? TraceID.random()
        // Sampling is decided once, at the root, and inherited: a child that re-rolled
        // could drop the middle of a trace and leave orphans on both sides of the gap.
        let sampled = parentContext?.sampled ?? shouldSample(traceId: traceId)

        let context = SpanContext(
            traceId: traceId,
            spanId: SpanID.random(),
            sampled: sampled,
            traceState: parentContext?.traceState
        )

        var initialAttributes = attributes
        if let sessionId = SessionSink.shared.currentSessionId {
            initialAttributes["session.id"] = .string(sessionId)
        }
        SessionSink.shared.recordTraceId(traceId.hex)

        return Span(
            context: context,
            parentSpanId: parentContext?.spanId,
            name: name,
            kind: kind,
            startTime: startTime,
            attributes: initialAttributes,
            onEnd: { [onSpanEnd] data in
                // An unsampled span is still created and still records its trace id — the
                // session should know a trace happened even when the span itself is not
                // exported — but it never reaches the queue.
                guard data.context.sampled else { return }
                onSpanEnd(data)
            }
        )
    }

    /// Run `body` inside a span, ending it however `body` leaves.
    @discardableResult
    public func withSpan<T>(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:],
        _ body: (Span) throws -> T
    ) rethrows -> T {
        let span = startSpan(name: name, kind: kind, attributes: attributes)
        defer { span.end() }
        do {
            return try TraceContext.withSpan(span) { try body(span) }
        } catch {
            span.setStatus(.error("\(error)"))
            throw error
        }
    }

    @discardableResult
    public func withSpan<T>(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:],
        _ body: (Span) async throws -> T
    ) async rethrows -> T {
        let span = startSpan(name: name, kind: kind, attributes: attributes)
        defer { span.end() }
        do {
            return try await TraceContext.withSpan(span) { try await body(span) }
        } catch {
            span.setStatus(.error("\(error)"))
            throw error
        }
    }

    /// Deterministic head sampling off the trace id, so every participant in a trace that
    /// uses the same rule reaches the same verdict. Matches the OTel `TraceIdRatioBased`
    /// sampler: compare the leading 8 bytes against the threshold.
    private func shouldSample(traceId: TraceID) -> Bool {
        let rate = options.tracesSampleRate
        if rate >= 1 { return true }
        if rate <= 0 { return false }
        let prefix = String(traceId.hex.prefix(16))
        guard let value = UInt64(prefix, radix: 16) else { return true }
        let threshold = UInt64(rate * Double(UInt64.max))
        return value < threshold
    }
}
