import Foundation

/// A distilled session event, on its way to `POST /v1/sessionEvents`.
///
/// Lives in `MapleCore` because both modules produce them and only one can send them:
/// taps and `track()` come from replay, network calls and screen appearances from
/// tracing, and the transport that batches them belongs to the recorder. Same split the
/// browser SDK has, where the event sink is a global in `browser-session` that both the
/// tracer and the recorder write into.
///
/// **The type set is closed at the gateway** — `SESSION_EVENT_TYPES`, seven values. A row
/// with any other type is *silently dropped*, not rejected, so a typo costs data with no
/// error to show for it. Hence the enum.
public struct SessionEventDraft: Sendable {
    public enum Kind: String, Sendable {
        case navigation, click, input, console, network, error, custom
    }

    public let kind: Kind
    public let timestamp: Date

    /// The trace this event belongs to.
    ///
    /// Explicit rather than resolved when the row is built: an event raised from a
    /// network callback or a `URLProtocol` is built on a thread where the caller's
    /// ambient context is long gone, so asking for "the active trace" there answers
    /// nothing. The producer already holds the span it is describing, so it says.
    /// `nil` means "resolve from the ambient context", which is right for `track()`.
    public let traceId: String?
    /// For `custom` this is the event name; for `navigation`, the screen.
    public let message: String
    public let url: String
    public let level: String
    public let attributes: [String: String]
    public let netMethod: String
    public let netUrl: String
    public let netStatus: Int
    public let netDurationMs: Int
    public let errorStack: String

    public init(
        kind: Kind,
        timestamp: Date = Date(),
        traceId: String? = nil,
        message: String = "",
        url: String = "",
        level: String = "",
        attributes: [String: String] = [:],
        netMethod: String = "",
        netUrl: String = "",
        netStatus: Int = 0,
        netDurationMs: Int = 0,
        errorStack: String = ""
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.traceId = traceId
        self.message = message
        self.url = url
        self.level = level
        self.attributes = attributes
        self.netMethod = netMethod
        self.netUrl = netUrl
        self.netStatus = netStatus
        self.netDurationMs = netDurationMs
        self.errorStack = errorStack
    }
}

extension SessionSink {
    /// Installed by the recorder. Events emitted while nothing is recording are dropped:
    /// a `session_events` row needs a `SessionId`, and inventing one would create a
    /// session in the UI with no recording behind it.
    public func setEventRelay(_ relay: ((SessionEventDraft) -> Void)?) {
        eventRelayLock.lock(); defer { eventRelayLock.unlock() }
        eventRelayBox.relay = relay
    }

    public func emit(_ draft: SessionEventDraft) {
        eventRelayLock.lock()
        let relay = eventRelayBox.relay
        eventRelayLock.unlock()
        relay?(draft)
    }
}
