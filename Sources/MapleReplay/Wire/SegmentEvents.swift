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
        events.append(contentsOf: extra)
        events.sort { $0.timestamp < $1.timestamp }
        return events
    }
}
