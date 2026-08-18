import Foundation

/// OTLP/JSON encoder.
///
/// JSON rather than protobuf because the gateway accepts both (`detect_payload_format`)
/// and protobuf would mean vendoring generated types or taking a SwiftProtobuf dependency
/// into every host app, for a payload measured in kilobytes.
///
/// The one rule that matters: **64-bit fields are decimal strings**, not JSON numbers.
/// The spec says a receiver must accept either, and Maple's gateway carries a shim that
/// normalises numbers precisely because so many exporters get this wrong — but the
/// underlying serde derives want strings, and a `Double`-backed JSON number cannot hold a
/// nanosecond timestamp without losing precision anyway.
enum OTLPEncoder {
    static func payload(spans: [SpanData], resource: [String: AttributeValue]) -> [String: Any] {
        [
            "resourceSpans": [[
                "resource": ["attributes": attributes(resource)],
                "scopeSpans": [[
                    "scope": [
                        "name": "dev.maple.tracing",
                        "version": MapleTracingVersion.current,
                    ],
                    "spans": spans.map(span),
                ]],
            ]],
        ]
    }

    static func encode(spans: [SpanData], resource: [String: AttributeValue]) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: payload(spans: spans, resource: resource),
            options: [.sortedKeys]
        )
    }

    private static func span(_ data: SpanData) -> [String: Any] {
        var out: [String: Any] = [
            "traceId": data.context.traceId.hex,
            "spanId": data.context.spanId.hex,
            "name": data.name,
            "kind": data.kind.rawValue,
            "startTimeUnixNano": nanoseconds(data.startTime),
            "endTimeUnixNano": nanoseconds(data.endTime),
            "attributes": attributes(data.attributes),
            "status": status(data.status),
        ]
        if let parent = data.parentSpanId {
            out["parentSpanId"] = parent.hex
        }
        if let traceState = data.context.traceState, !traceState.isEmpty {
            out["traceState"] = traceState
        }
        // `01` = sampled. Anything reaching the encoder is sampled by construction — the
        // tracer drops the rest at `end()` — but the field is not optional in practice:
        // a collector that sees flags `00` may treat the span as dropped.
        out["flags"] = data.context.sampled ? 1 : 0
        return out
    }

    private static func status(_ status: SpanStatus) -> [String: Any] {
        var out: [String: Any] = ["code": status.otlpCode]
        if case .error(let message) = status, !message.isEmpty {
            out["message"] = message
        }
        return out
    }

    private static func attributes(_ attributes: [String: AttributeValue]) -> [[String: Any]] {
        attributes
            .sorted { $0.key < $1.key }  // stable output; makes a wire-format test assertable
            .map { ["key": $0.key, "value": $0.value.otlpValue] }
    }

    /// Nanoseconds since the epoch, as a decimal string.
    ///
    /// Built from seconds and the fraction separately rather than
    /// `timeIntervalSince1970 * 1e9`. `Date` is already a `Double` of seconds, so it
    /// carries about 240 ns of resolution at a 2026 epoch and no encoding can recover
    /// more than that. What the split avoids is *adding* to it: the naive product is
    /// ~1.8e18, past 2^53, where the nearest representable `Double` is 256 ns away — so
    /// the multiply would round a second time, on top of the rounding `Date` already did.
    /// The integer seconds go through exactly and only the small fraction is scaled.
    static func nanoseconds(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        let seconds = interval.rounded(.down)
        let fraction = interval - seconds
        let nanos = UInt64(seconds) &* 1_000_000_000 &+ UInt64((fraction * 1_000_000_000).rounded())
        return String(nanos)
    }
}

enum MapleTracingVersion {
    static let current = "0.2.0"
}
