import CoreGraphics
import Foundation

/// Builds the rrweb event array for one segment.
///
/// Shared by live emission and crash recovery on purpose: a recovered segment is an
/// ordinary segment that happens to have been encoded on the next launch, and the two
/// paths drifting apart is exactly how a player ends up unable to read one of them.
enum SegmentEvents {
    static func build(
        sessionId: String,
        chunkSeq: Int,
        video: EncodedVideo,
        start: Date,
        reason: String,
        pointSize: CGSize? = nil,
        touches: [TouchSample] = [],
        extra: [RRWebEvent] = []
    ) -> [RRWebEvent] {
        var events: [RRWebEvent] = [
            .meta(
                timestamp: start,
                width: video.width,
                height: video.height,
                href: "maple://replay/\(sessionId)"
            ),
            .video(
                timestamp: start,
                segmentId: chunkSeq,
                size: video.byteSize,
                durationMs: Int((video.duration * 1000).rounded()),
                width: video.width,
                height: video.height,
                frameCount: video.frameCount,
                frameRate: video.frameRate,
                base64: (try? Data(contentsOf: video.url).base64EncodedString()) ?? ""
            ),
            .breadcrumb(
                timestamp: start,
                category: "replay.segment",
                message: reason,
                data: ["frameCount": video.frameCount]
            ),
        ]
        events.append(contentsOf: touchEvents(touches, video: video, start: start, pointSize: pointSize))
        events.append(contentsOf: extra)
        // Stable, with the meta event pinned first: the player takes the first event's
        // timestamp as the recording's time zero.
        let meta = events.removeFirst()
        events = events.enumerated()
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)
        return [meta] + events.filter { $0.timestamp >= meta.timestamp }
    }

    /// Touches that happened while this segment's video was on screen, in the video's
    /// pixel space so an overlay lines up with the frame without knowing the tier.
    ///
    /// Anything earlier is dropped rather than clamped: in a buffered session touches
    /// older than the window would otherwise land before the meta event and drag the
    /// player's time zero back with them.
    static func touchEvents(
        _ touches: [TouchSample],
        video: EncodedVideo,
        start: Date,
        pointSize: CGSize?
    ) -> [RRWebEvent] {
        let end = start.addingTimeInterval(video.duration)
        let points = pointSize ?? CGSize(width: video.width, height: video.height)
        let scaleX = points.width > 0 ? CGFloat(video.width) / points.width : 1
        let scaleY = points.height > 0 ? CGFloat(video.height) / points.height : 1
        return touches
            .filter { $0.timestamp >= start && $0.timestamp <= end }
            .map {
                .touch(
                    timestamp: $0.timestamp,
                    interaction: $0.interaction,
                    x: $0.location.x * scaleX,
                    y: $0.location.y * scaleY
                )
            }
    }
}
