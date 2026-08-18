import Foundation

/// An OTLP attribute value.
///
/// An enum rather than `Any` so encoding is *total*: every case has exactly one OTLP
/// representation and there is no run-time branch that can fail to encode. A `[String: Any]`
/// attribute bag pushes that failure to the exporter, where the only options are dropping
/// the span or emitting something the collector rejects.
public enum AttributeValue: Equatable, Sendable {
    case string(String)
    case int(Int64)
    case double(Double)
    case bool(Bool)
    case stringArray([String])

    var otlpValue: [String: Any] {
        switch self {
        case .string(let value): return ["stringValue": value]
        case .int(let value): return ["intValue": String(value)]  // 64-bit ints are strings in OTLP/JSON
        case .double(let value): return ["doubleValue": value]
        case .bool(let value): return ["boolValue": value]
        case .stringArray(let values):
            return ["arrayValue": ["values": values.map { ["stringValue": $0] }]]
        }
    }
}

public enum SpanKind: Int, Sendable {
    case unspecified = 0
    case `internal` = 1
    case server = 2
    case client = 3
    case producer = 4
    case consumer = 5
}

/// Title Case, matching Maple's convention across every language in the platform.
public enum SpanStatus: Equatable, Sendable {
    case unset
    case ok
    case error(String)

    var otlpCode: Int {
        switch self {
        case .unset: return 0
        case .ok: return 1
        case .error: return 2
        }
    }
}

/// A finished span, ready to encode. Immutable — the mutable thing is `Span`.
public struct SpanData: Sendable {
    public let context: SpanContext
    public let parentSpanId: SpanID?
    public let name: String
    public let kind: SpanKind
    public let startTime: Date
    public let endTime: Date
    public let attributes: [String: AttributeValue]
    public let status: SpanStatus
}

/// An in-progress span.
///
/// Deliberately a class with a lock: a span started on the main thread is routinely ended
/// from a `URLSession` completion queue, and the attribute writes in between come from
/// whichever thread the host app happens to be on.
public final class Span: @unchecked Sendable {
    public let context: SpanContext
    public let parentSpanId: SpanID?
    public let name: String
    public let kind: SpanKind
    public let startTime: Date

    private let lock = NSLock()
    private var attributes: [String: AttributeValue]
    private var status: SpanStatus = .unset
    private var endTime: Date?
    private let onEnd: (SpanData) -> Void

    init(
        context: SpanContext,
        parentSpanId: SpanID?,
        name: String,
        kind: SpanKind,
        startTime: Date,
        attributes: [String: AttributeValue],
        onEnd: @escaping (SpanData) -> Void
    ) {
        self.context = context
        self.parentSpanId = parentSpanId
        self.name = name
        self.kind = kind
        self.startTime = startTime
        self.attributes = attributes
        self.onEnd = onEnd
    }

    public var traceId: String { context.traceId.hex }
    public var spanId: String { context.spanId.hex }

    public func setAttribute(_ key: String, _ value: AttributeValue) {
        lock.lock(); defer { lock.unlock() }
        guard endTime == nil else { return }
        attributes[key] = value
    }

    public func setAttribute(_ key: String, _ value: String) { setAttribute(key, .string(value)) }
    public func setAttribute(_ key: String, _ value: Int) { setAttribute(key, .int(Int64(value))) }
    public func setAttribute(_ key: String, _ value: Bool) { setAttribute(key, .bool(value)) }

    public func setStatus(_ newStatus: SpanStatus) {
        lock.lock(); defer { lock.unlock() }
        guard endTime == nil else { return }
        status = newStatus
    }

    /// Finish the span. Idempotent — a `URLSession` task can report completion twice
    /// (delegate *and* completion handler), and a double-ended span would be exported
    /// twice under the same id.
    public func end(at time: Date = Date()) {
        lock.lock()
        guard endTime == nil else { lock.unlock(); return }
        endTime = time
        let data = SpanData(
            context: context,
            parentSpanId: parentSpanId,
            name: name,
            kind: kind,
            startTime: startTime,
            endTime: time,
            attributes: attributes,
            status: status
        )
        lock.unlock()
        onEnd(data)
    }
}
