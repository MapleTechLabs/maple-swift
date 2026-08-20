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

/// A timestamped event on a span.
///
/// The only one Maple reads today is `exception`: `error_events_mv` keys on a span whose
/// `StatusCode` is `Error` *and* which carries an event named `exception`, and reads the
/// error's type, message and stack out of that event's attributes. A span carrying one
/// without the other produces no error row, which is why `recordException` sets both.
public struct SpanEvent: Equatable, Sendable {
    public let name: String
    public let timestamp: Date
    public let attributes: [String: AttributeValue]

    public init(name: String, timestamp: Date = Date(), attributes: [String: AttributeValue] = [:]) {
        self.name = name
        self.timestamp = timestamp
        self.attributes = attributes
    }
}

/// OTel's semantic convention for an exception event.
public enum ExceptionSemantics {
    public static let eventName = "exception"
    public static let type = "exception.type"
    public static let message = "exception.message"
    public static let stacktrace = "exception.stacktrace"

    static func event(
        type: String,
        message: String,
        stacktrace: String?,
        timestamp: Date
    ) -> SpanEvent {
        var attributes: [String: AttributeValue] = [
            Self.type: .string(type),
            Self.message: .string(message),
        ]
        if let stacktrace, !stacktrace.isEmpty {
            attributes[Self.stacktrace] = .string(stacktrace)
        }
        return SpanEvent(name: Self.eventName, timestamp: timestamp, attributes: attributes)
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
    public let events: [SpanEvent]
    /// Resource attributes that replace the exporter's for this span alone.
    ///
    /// Empty for everything the app produces live, because the exporter's resource *is*
    /// this process. A crash span is the exception: it describes a run of a possibly
    /// different build, and reporting it under the running version would file every
    /// pre-update crash against the update that fixed it.
    public let resourceOverrides: [String: AttributeValue]

    public init(
        context: SpanContext,
        parentSpanId: SpanID?,
        name: String,
        kind: SpanKind,
        startTime: Date,
        endTime: Date,
        attributes: [String: AttributeValue],
        status: SpanStatus,
        events: [SpanEvent] = [],
        resourceOverrides: [String: AttributeValue] = [:]
    ) {
        self.context = context
        self.parentSpanId = parentSpanId
        self.name = name
        self.kind = kind
        self.startTime = startTime
        self.endTime = endTime
        self.attributes = attributes
        self.status = status
        self.events = events
        self.resourceOverrides = resourceOverrides
    }
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
    private var events: [SpanEvent] = []
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

    public func addEvent(_ name: String, attributes: [String: AttributeValue] = [:], at time: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        guard endTime == nil else { return }
        events.append(SpanEvent(name: name, timestamp: time, attributes: attributes))
    }

    /// Record an exception on this span and mark it failed.
    ///
    /// Both halves are required for the error to reach Maple's `/errors`, so this does
    /// them together rather than leaving a caller to discover that an `exception` event
    /// on an `Ok` span is silently invisible.
    public func recordException(
        type: String,
        message: String,
        stacktrace: String? = nil,
        at time: Date = Date()
    ) {
        lock.lock()
        guard endTime == nil else { lock.unlock(); return }
        events.append(ExceptionSemantics.event(type: type, message: message, stacktrace: stacktrace, timestamp: time))
        status = .error(message)
        lock.unlock()
    }

    /// `recordException` for a caught Swift error.
    ///
    /// The type is the concrete Swift type name rather than the enum case, so the label
    /// in Maple stays stable while a case's payload varies.
    public func recordError(_ error: Error, stacktrace: String? = nil, at time: Date = Date()) {
        recordException(
            type: String(describing: Swift.type(of: error)),
            message: String(describing: error),
            stacktrace: stacktrace,
            at: time
        )
    }

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
            status: status,
            events: events
        )
        lock.unlock()
        onEnd(data)
    }
}
