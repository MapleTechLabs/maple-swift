import Foundation
import MapleCore

/// What a single flushed segment produced.
public struct SegmentArtifacts: Sendable {
    public let chunkSeq: Int
    public let isCheckpoint: Bool
    /// Size of the gzipped chunk — this is what the POST body weighs.
    public let gzippedBytes: Int
    public let rawJSONBytes: Int
    public let videoBytes: Int
    public let frameCount: Int
    public let eventCount: Int
    public let durationMs: Int
    /// Where the chunk and its video were written, when `writeSegmentsToDisk` is on.
    /// `nil` on the upload-only path, which never touches the filesystem.
    public let chunkURL: URL?
    public let videoURL: URL?
}

/// A flushed segment, ready to send: the record of what it is, plus the exact bytes of
/// the `POST /v1/sessionReplays/blob` body.
struct PreparedSegment {
    let artifacts: SegmentArtifacts
    let body: Data
}

/// Turns a flushed segment into the request that carries it.
///
/// The gzipped JSON array it produces *is* the body of `POST /v1/sessionReplays/blob`,
/// and `headers` returns the `x-maple-*` values that accompany it. Milestone 1 wrote
/// those bytes to disk instead of sending them; milestone 2 sends them and keeps the disk
/// write as a debugging switch, which is the whole reason the bytes were shaped this way
/// up front.
struct SegmentWriter {
    let directory: URL
    let sessionId: String
    /// Also write the chunk and its MP4 to `directory`. Off on the upload path — it is a
    /// debugging affordance, not part of the pipeline.
    let persistToDisk: Bool

    func prepare(
        video: EncodedVideo,
        events: [RRWebEvent],
        chunkSeq: Int,
        isCheckpoint: Bool
    ) throws -> PreparedSegment {
        let json = events.map(\.json)
        let rawJSON = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        guard let gzipped = Gzip.compress(rawJSON) else {
            throw SegmentWriterError.compressionFailed
        }

        var chunkURL: URL?
        var videoURL: URL?
        if persistToDisk {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // The MP4 is kept beside the chunk, unreferenced by the wire format, purely
            // so a human can double-click it to verify redaction. It is never uploaded —
            // the video already rides inside the chunk as base64.
            let destination = directory.appendingPathComponent(String(format: "segment-%03d.mp4", chunkSeq))
            if video.url != destination {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: video.url, to: destination)
            }
            videoURL = destination

            let url = directory.appendingPathComponent(String(format: "segment-%03d.json.gz", chunkSeq))
            try gzipped.write(to: url, options: .atomic)
            chunkURL = url
        } else {
            // Nothing else refers to the encoder's temporary file once its bytes are in
            // the chunk. Leaving it behind would grow the caches directory by one MP4
            // per segment, forever.
            try? FileManager.default.removeItem(at: video.url)
        }

        let durationMs = Int((video.duration * 1000).rounded())

        return PreparedSegment(
            artifacts: SegmentArtifacts(
                chunkSeq: chunkSeq,
                isCheckpoint: isCheckpoint,
                gzippedBytes: gzipped.count,
                rawJSONBytes: rawJSON.count,
                videoBytes: video.byteSize,
                frameCount: video.frameCount,
                eventCount: events.count,
                durationMs: durationMs,
                chunkURL: chunkURL,
                videoURL: videoURL
            ),
            body: gzipped
        )
    }

    /// The headers that accompany this chunk on `POST /v1/sessionReplays/blob`.
    static func headers(
        sessionId: String,
        chunkSeq: Int,
        isCheckpoint: Bool,
        eventCount: Int,
        durationMs: Int
    ) -> [String: String] {
        [
            "x-maple-session-id": sessionId,
            "x-maple-chunk-seq": String(chunkSeq),
            "x-maple-is-checkpoint": isCheckpoint ? "1" : "0",
            "x-maple-event-count": String(eventCount),
            "x-maple-duration-ms": String(durationMs),
        ]
    }

    /// A new session id.
    ///
    /// **Lowercased, and that is load-bearing.** `UUID().uuidString` is uppercase on
    /// Apple platforms while JavaScript's `crypto.randomUUID()` is lowercase, and the
    /// backend's public-id codec is not case-preserving: it encodes `srep_…` from the
    /// raw id and decodes it back through lowercase hex. So an uppercase id survives
    /// ingestion, is stored verbatim in the warehouse, and is then looked up in
    /// lowercase — matching nothing. The session lists (that read path uses the raw id)
    /// and plays back empty.
    ///
    /// Nothing rejects an uppercase id along the way; the gateway's own validator
    /// accepts `[A-Za-z0-9_-]`. Lowercasing here is what keeps the id that goes out
    /// equal to the id that comes back.
    static func newSessionId() -> String {
        UUID().uuidString.lowercased()
    }

    /// Maple's gateway rejects session ids that don't match `is_safe_replay_id`:
    /// at most 128 characters of `[A-Za-z0-9_-]`. A bare `UUID().uuidString` qualifies
    /// (hyphens are allowed); anything with braces or colons does not.
    ///
    /// Note this accepts uppercase, which is why `newSessionId()` has to lowercase —
    /// validation here is not what keeps the id round-trippable.
    static func isSafeSessionId(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 128 else { return false }
        return id.allSatisfy { character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
        }
    }
}

enum SegmentWriterError: Error {
    case compressionFailed
}
