import AVFoundation
import Compression
import CoreGraphics
import Foundation

enum WirePath {
    static let meta = "/v1/sessionReplays/meta"
    static let blob = "/v1/sessionReplays/blob"
    static let events = "/v1/sessionEvents"
    static let traces = "/v1/traces"
}

/// One `/v1/sessionReplays/meta` row.
struct MetaRow {
    let json: [String: Any]
    let receivedAt: Date

    var sessionId: String { json["session_id"] as? String ?? "" }
    var status: String { json["status"] as? String ?? "" }
    var version: Int { json["version"] as? Int ?? -1 }
    var userId: String { json["user_id"] as? String ?? "" }
    var attributes: [String: String] { json["resource_attributes"] as? [String: String] ?? [:] }
    var recorded: String? { attributes["maple.session.recorded"] }
}

/// One `/v1/sessionReplays/blob` request, decoded.
struct Blob {
    let request: RecordedRequest
    let events: [[String: Any]]

    var sessionId: String { request.headers["x-maple-session-id"] ?? "" }
    var chunkSeq: Int { Int(request.headers["x-maple-chunk-seq"] ?? "") ?? -1 }
    var receivedAt: Date { request.receivedAt }

    var videoEvents: [[String: Any]] {
        events.filter { ($0["type"] as? Int) == 5 && (($0["data"] as? [String: Any])?["tag"] as? String) == "video" }
    }

    var videoPayload: [String: Any]? {
        (videoEvents.first?["data"] as? [String: Any])?["payload"] as? [String: Any]
    }

    /// Epoch ms of the meta event, which the player treats as the segment's time zero.
    var startMs: Int { events.first?["timestamp"] as? Int ?? 0 }

    /// Touch events, `incrementalSnapshot` from source 2, in video pixels.
    var touches: [(type: Int, x: Int, y: Int, timestamp: Int)] {
        events.compactMap { event in
            guard (event["type"] as? Int) == 3, let data = event["data"] as? [String: Any],
                  (data["source"] as? Int) == 2,
                  let type = data["type"] as? Int, let x = data["x"] as? Int, let y = data["y"] as? Int
            else { return nil }
            return (type, x, y, event["timestamp"] as? Int ?? 0)
        }
    }

    func breadcrumbs(category: String) -> [[String: Any]] {
        events.compactMap { event in
            guard (event["type"] as? Int) == 5, let data = event["data"] as? [String: Any],
                  data["tag"] as? String == "breadcrumb",
                  let payload = data["payload"] as? [String: Any],
                  payload["category"] as? String == category
            else { return nil }
            return payload
        }
    }

    /// The MP4 the video event carries, decoded frame by frame.
    func decodeVideo() throws -> DecodedVideo {
        guard let base64 = videoPayload?["base64"] as? String, let mp4 = Data(base64Encoded: base64) else {
            throw WireError.noVideo
        }
        return try DecodedVideo(mp4: mp4)
    }
}

extension MockIngestServer {
    var metaRows: [MetaRow] {
        requests.filter { $0.path == WirePath.meta }
            .flatMap { request in
                Wire.ndjson(request.body).map { MetaRow(json: $0, receivedAt: request.receivedAt) }
            }
    }

    var blobRequests: [RecordedRequest] { requests.filter { $0.path == WirePath.blob } }

    /// Every blob, decoded. A body that does not decode fails the decode for the caller
    /// rather than being skipped, since that is itself an SDK bug.
    func blobs() throws -> [Blob] {
        try blobRequests.map { request in
            guard let json = Wire.gunzip(request.body),
                  let events = try JSONSerialization.jsonObject(with: json) as? [[String: Any]] else {
                throw WireError.undecodableBlob(request.headers["x-maple-chunk-seq"] ?? "?")
            }
            return Blob(request: request, events: events)
        }
    }

    var eventRows: [[String: Any]] {
        requests.filter { $0.path == WirePath.events }.flatMap { Wire.ndjson($0.body) }
    }

    /// Session id a replay request belongs to, from the header or the NDJSON body.
    func sessionIds(of request: RecordedRequest) -> Set<String> {
        if let header = request.headers["x-maple-session-id"] { return [header] }
        return Set(Wire.ndjson(request.body).compactMap { $0["session_id"] as? String })
    }

    func replayRequests(for sessionId: String) -> [RecordedRequest] {
        requests.filter { [WirePath.meta, WirePath.blob, WirePath.events].contains($0.path) }
            .filter { sessionIds(of: $0).contains(sessionId) }
    }
}

enum Wire {
    static func ndjson(_ body: Data) -> [[String: Any]] {
        body.split(separator: 0x0A).compactMap { line in
            (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
        }
    }

    /// RFC 1952 container around raw DEFLATE. The SDK never sets optional header fields,
    /// so the header is the fixed 10 bytes; ISIZE in the trailer sizes the output.
    static func gunzip(_ data: Data) -> Data? {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else { return nil }
        let deflated = Data(data.dropFirst(10).dropLast(8))
        let isize = data.suffix(4).reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let capacity = max(1, Int(isize))
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            deflated.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, deflated.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == capacity else { return nil }
        return output
    }
}

/// A decoded MP4: track geometry plus every frame as BGRA pixels.
struct DecodedVideo {
    let width: Int
    let height: Int
    let duration: Double
    let frames: [VideoFrame]

    init(mp4: Data) throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("e2e-\(UUID().uuidString).mp4")
        try mp4.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw WireError.noVideo }
        let size = track.naturalSize.applying(track.preferredTransform)
        width = Int(abs(size.width).rounded())
        height = Int(abs(size.height).rounded())
        duration = asset.duration.seconds

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? WireError.noVideo }

        var frames: [VideoFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            frames.append(VideoFrame(pixels, time: CMSampleBufferGetPresentationTimeStamp(sample).seconds))
        }
        if reader.status == .failed { throw reader.error ?? WireError.noVideo }
        self.frames = frames
    }
}

struct VideoFrame {
    let width: Int
    let height: Int
    let time: Double
    private let bytesPerRow: Int
    private let bytes: [UInt8]

    init(_ buffer: CVPixelBuffer, time: Double) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        width = CVPixelBufferGetWidth(buffer)
        height = CVPixelBufferGetHeight(buffer)
        bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        bytes = Array(UnsafeBufferPointer(start: base, count: bytesPerRow * height))
        self.time = time
    }

    /// Mean colour over `rect` (video pixels), clipped to the frame.
    func meanColor(in rect: CGRect) -> (r: Double, g: Double, b: Double) {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return (0, 0, 0) }
        var r = 0.0, g = 0.0, b = 0.0, count = 0.0
        for y in Int(clipped.minY)..<Int(clipped.maxY) {
            for x in Int(clipped.minX)..<Int(clipped.maxX) {
                let offset = y * bytesPerRow + x * 4
                b += Double(bytes[offset]); g += Double(bytes[offset + 1]); r += Double(bytes[offset + 2])
                count += 1
            }
        }
        return (r / count, g / count, b / count)
    }

    /// Brightest pixel's luma in `rect`: a mask must leave nothing light behind, so the
    /// maximum is the honest test, not the mean.
    func maxLuma(in rect: CGRect) -> Double {
        let clipped = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return 0 }
        var brightest = 0.0
        for y in Int(clipped.minY)..<Int(clipped.maxY) {
            for x in Int(clipped.minX)..<Int(clipped.maxX) {
                let offset = y * bytesPerRow + x * 4
                let luma = 0.0722 * Double(bytes[offset]) + 0.7152 * Double(bytes[offset + 1]) + 0.2126 * Double(bytes[offset + 2])
                brightest = max(brightest, luma)
            }
        }
        return brightest
    }
}

enum WireError: Error {
    case noVideo
    case undecodableBlob(String)
}
