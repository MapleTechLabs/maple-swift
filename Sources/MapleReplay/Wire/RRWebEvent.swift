import CoreGraphics
import Foundation

/// rrweb event type tags.
///
/// Mobile replay is not rrweb — there is no DOM to serialise. We nonetheless emit
/// rrweb-shaped events, because the whole chunk pipeline downstream (Maple's
/// `session_replay_events` rows, the R2 key scheme, the manifest, the ranged chunk
/// loader, and the web player) already speaks this shape. Sentry made the same choice for
/// the same reason: a video segment rides inside a `custom` event, and everything else in
/// the stack keeps working untouched.
enum RRWebEventType: Int, Codable {
    case domContentLoaded = 0
    case load = 1
    case fullSnapshot = 2
    case incrementalSnapshot = 3
    case meta = 4
    case custom = 5
}

/// rrweb `IncrementalSource` values we emit. Only mouse interaction is meaningful for a
/// video-backed replay — the rest describe DOM mutations we don't have.
enum RRWebIncrementalSource: Int, Codable {
    case mouseInteraction = 2
}

/// rrweb `MouseInteractions` values. Touches map onto the touch-specific variants so a
/// player can distinguish them from synthetic pointer events.
public enum TouchInteraction: Int, Codable, Sendable {
    case touchStart = 7
    case touchMove = 8
    case touchEnd = 9
}

/// One serialised rrweb event. Encoded as a plain JSON object rather than a Swift enum
/// with associated values, because the payload shape differs per type and the wire format
/// is the contract — not our type model.
struct RRWebEvent {
    let type: RRWebEventType
    /// Milliseconds since epoch. rrweb timestamps are integer ms, not seconds.
    let timestamp: Int
    let data: [String: Any]

    var json: [String: Any] {
        ["type": type.rawValue, "timestamp": timestamp, "data": data]
    }

    static func meta(timestamp: Date, width: Int, height: Int, href: String) -> RRWebEvent {
        RRWebEvent(
            type: .meta,
            timestamp: timestamp.epochMilliseconds,
            data: ["href": href, "width": width, "height": height]
        )
    }

    /// The video segment itself, as an rrweb custom event.
    ///
    /// Field names and units match `SentryRRWebVideoEvent` so that a player written for
    /// one can read the other: `duration` is milliseconds, `size` is the encoded byte
    /// count, `left`/`top` position the video within the meta viewport.
    static func video(
        timestamp: Date,
        segmentId: Int,
        size: Int,
        durationMs: Int,
        width: Int,
        height: Int,
        frameCount: Int,
        frameRate: Int,
        base64: String
    ) -> RRWebEvent {
        RRWebEvent(
            type: .custom,
            timestamp: timestamp.epochMilliseconds,
            data: [
                "tag": "video",
                "payload": [
                    "segmentId": segmentId,
                    "size": size,
                    "duration": durationMs,
                    "encoding": "h264",
                    "container": "mp4",
                    "width": width,
                    "height": height,
                    "frameCount": frameCount,
                    "frameRateType": "constant",
                    "frameRate": frameRate,
                    "left": 0,
                    "top": 0,
                    // The MP4 travels inside the JSON rather than as a separate binary
                    // upload. Maple's blob endpoint takes one gzipped JSON body and never
                    // inspects it, so this keeps a mobile SDK working against the existing
                    // gateway with no server change at all.
                    "base64": base64,
                ],
            ]
        )
    }

    static func touch(
        timestamp: Date,
        interaction: TouchInteraction,
        x: CGFloat,
        y: CGFloat
    ) -> RRWebEvent {
        RRWebEvent(
            type: .incrementalSnapshot,
            timestamp: timestamp.epochMilliseconds,
            data: [
                "source": RRWebIncrementalSource.mouseInteraction.rawValue,
                "type": interaction.rawValue,
                // rrweb addresses targets by DOM node id. There are no nodes here, so we
                // pin to the root id the meta event implies.
                "id": 0,
                "x": Int(x.rounded()),
                "y": Int(y.rounded()),
                "pointerType": 2,
            ]
        )
    }

    static func breadcrumb(timestamp: Date, category: String, message: String?, data: [String: Any] = [:]) -> RRWebEvent {
        var payload: [String: Any] = ["category": category, "data": data]
        payload["message"] = message
        payload["timestamp"] = timestamp.timeIntervalSince1970
        return RRWebEvent(
            type: .custom,
            timestamp: timestamp.epochMilliseconds,
            data: ["tag": "breadcrumb", "payload": payload]
        )
    }
}

extension Date {
    var epochMilliseconds: Int { Int((timeIntervalSince1970 * 1000).rounded()) }
}
