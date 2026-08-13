import Foundation

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
    enum Kind: String {
        case navigation, click, input, console, network, error, custom
    }

    let sessionId: String
    let seq: Int
    let type: Kind
    let timestamp: Date
    /// For `custom`, this is the event name; the gateway truncates past 1 KiB.
    let message: String
    /// For `custom`, `track()`'s properties. The gateway keeps the first 32.
    let attributes: [String: String]

    init(
        sessionId: String,
        seq: Int,
        type: Kind,
        timestamp: Date = Date(),
        message: String = "",
        attributes: [String: String] = [:]
    ) {
        self.sessionId = sessionId
        self.seq = seq
        self.type = type
        self.timestamp = timestamp
        self.message = message
        self.attributes = attributes
    }

    func json() -> [String: Any] {
        [
            "session_id": sessionId,
            "timestamp": SessionMetaRow.clickHouseDateTime(timestamp),
            "seq": seq,
            "type": type.rawValue,
            "url": "",
            "trace_id": "",
            "level": "",
            "message": message,
            "target_selector": "",
            "target_text": "",
            "net_method": "",
            "net_url": "",
            "net_status": 0,
            "net_duration_ms": 0,
            "error_stack": "",
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
