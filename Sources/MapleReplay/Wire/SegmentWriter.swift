import Foundation

/// What a single flushed segment produced.
public struct SegmentArtifacts: Sendable {
    public let chunkSeq: Int
    public let videoURL: URL
    public let chunkURL: URL
    /// Size of the gzipped chunk — this is what a POST body would weigh.
    public let gzippedBytes: Int
    public let rawJSONBytes: Int
    public let videoBytes: Int
    public let frameCount: Int
    public let durationMs: Int
}

/// Writes a flushed segment to disk in exactly the form it would be transmitted.
///
/// The chunk file is the gzipped JSON array that would become the body of
/// `POST /v1/sessionReplays/blob`, and `headers` returns the `x-maple-*` values that
/// would accompany it. Milestone 2 replaces the file write with a request and changes
/// nothing else — that is the point of writing it this way now.
struct SegmentWriter {
    let directory: URL
    let sessionId: String

    func write(
        video: EncodedVideo,
        events: [RRWebEvent],
        chunkSeq: Int,
        isCheckpoint: Bool
    ) throws -> SegmentArtifacts {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // The MP4 is also kept beside the chunk, unreferenced by the wire format, purely
        // so a human can double-click it to verify redaction. It would not be uploaded.
        let videoURL = directory.appendingPathComponent(String(format: "segment-%03d.mp4", chunkSeq))
        if video.url != videoURL {
            try? FileManager.default.removeItem(at: videoURL)
            try FileManager.default.moveItem(at: video.url, to: videoURL)
        }

        let json = events.map(\.json)
        let rawJSON = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        guard let gzipped = Gzip.compress(rawJSON) else {
            throw SegmentWriterError.compressionFailed
        }

        let chunkURL = directory.appendingPathComponent(
            String(format: "segment-%03d.json.gz", chunkSeq)
        )
        try gzipped.write(to: chunkURL, options: .atomic)

        let durationMs = Int((video.duration * 1000).rounded())

        return SegmentArtifacts(
            chunkSeq: chunkSeq,
            videoURL: videoURL,
            chunkURL: chunkURL,
            gzippedBytes: gzipped.count,
            rawJSONBytes: rawJSON.count,
            videoBytes: video.byteSize,
            frameCount: video.frameCount,
            durationMs: durationMs
        )
    }

    /// The headers that would accompany this chunk on `POST /v1/sessionReplays/blob`.
    ///
    /// Written out now so the header contract is exercised (and reviewable) before there
    /// is any networking code to get it wrong.
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

    /// Maple's gateway rejects session ids that don't match `is_safe_replay_id`:
    /// at most 128 characters of `[A-Za-z0-9_-]`. A bare `UUID().uuidString` qualifies
    /// (hyphens are allowed); anything with braces or colons does not.
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
