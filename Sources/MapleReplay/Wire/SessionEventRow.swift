import Foundation
import MapleCore

/// One distilled session event — a row of `POST /v1/sessionEvents`.
///
/// Shape taken from `toRow` in `packages/browser-session/src/events-sink.ts`. The type
/// set is closed **at the gateway** (`SESSION_EVENT_TYPES`, seven values): a row with any
/// other `type` is silently dropped, not rejected, so a typo here costs data with no
/// error to show for it. Hence the enum.
///
/// Web-shaped columns with no mobile analogue are sent empty rather than repurposed, for
/// the same reason the metadata row does it — a `url` facet should never show a screen
/// name pretending to be a URL.
struct SessionEventRow {
    typealias Kind = SessionEventDraft.Kind

    let sessionId: String
    let seq: Int
    let type: Kind
    let timestamp: Date
    /// For `custom`, this is the event name; the gateway truncates past 1 KiB.
    let message: String
    /// For `custom`, `track()`'s properties. The gateway keeps the first 32.
    let attributes: [String: String]
    /// The trace this event happened inside — the third of the three links between a
    /// session and its traces, and the one the transcript uses to jump to a waterfall.
    /// Empty when tracing is not running, which is the pre-tracing behaviour unchanged.
    let traceId: String
    let url: String
    let level: String
    let netMethod: String
    let netUrl: String
    let netStatus: Int
    let netDurationMs: Int
    let errorStack: String

    init(
        sessionId: String,
        seq: Int,
        type: Kind,
        timestamp: Date = Date(),
        message: String = "",
        attributes: [String: String] = [:],
        traceId: String? = nil,
        url: String = "",
        level: String = "",
        netMethod: String = "",
        netUrl: String = "",
        netStatus: Int = 0,
        netDurationMs: Int = 0,
        errorStack: String = ""
    ) {
        self.sessionId = sessionId
        self.seq = seq
        self.type = type
        self.timestamp = timestamp
        self.message = message
        self.attributes = attributes
        // Resolved at construction, not at encode: by the time a batch is posted the
        // span that produced the event is long gone.
        self.traceId = traceId ?? SessionSink.shared.activeTraceId ?? ""
        self.url = url
        self.level = level
        self.netMethod = netMethod
        self.netUrl = netUrl
        self.netStatus = netStatus
        self.netDurationMs = netDurationMs
        self.errorStack = errorStack
    }

    /// Build a row from an event raised by another module (tracing, today).
    init(sessionId: String, seq: Int, draft: SessionEventDraft) {
        self.init(
            sessionId: sessionId,
            seq: seq,
            type: draft.kind,
            timestamp: draft.timestamp,
            message: draft.message,
            attributes: draft.attributes,
            traceId: draft.traceId,
            url: draft.url,
            level: draft.level,
            netMethod: draft.netMethod,
            netUrl: draft.netUrl,
            netStatus: draft.netStatus,
            netDurationMs: draft.netDurationMs,
            errorStack: draft.errorStack
        )
    }

    func json() -> [String: Any] {
        [
            "session_id": sessionId,
            "timestamp": SessionMetaRow.clickHouseDateTime(timestamp),
            "seq": seq,
            "type": type.rawValue,
            "url": url,
            "trace_id": traceId,
            "level": level,
            "message": message,
            "target_selector": "",
            "target_text": "",
            "net_method": netMethod,
            "net_url": netUrl,
            "net_status": netStatus,
            "net_duration_ms": netDurationMs,
            "error_stack": errorStack,
            "attributes": attributes,
        ]
    }

    /// One NDJSON line, newline-terminated.
    func ndjson() throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: json(), options: [.sortedKeys])
        data.append(0x0A)
        return data
    }
}
