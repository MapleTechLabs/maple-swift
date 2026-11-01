import AVFoundation
import Foundation
import UIKit

struct EncodedVideo {
    let url: URL
    let byteSize: Int
    let width: Int
    let height: Int
    let frameCount: Int
    let frameRate: Int
    let duration: TimeInterval
    let start: Date
}

enum VideoEncoderError: Error {
    case noFrames
    case writerSetupFailed(String)
    case pixelBufferPoolUnavailable
    case encodeFailed(String)
    case timedOut(String)
}

/// Encodes buffered JPEG frames into an H.264/MP4 segment via AVAssetWriter.
///
/// Presentation times come from each frame's capture timestamp, not its index. Capture
/// misses ticks whenever the main thread is busy, and an index-based clock then plays
/// the segment faster than it happened, drifting every touch and transcript event off
/// the frame it belongs to. The last frame is held for one nominal frame interval.
enum VideoEncoder {
    /// Ceiling on any one wait inside an encode. AVAssetWriter can stop accepting input
    /// without ever reporting failure, and this runs on the queue every later segment
    /// waits behind, so a stuck writer must cost one segment, never the session.
    static let stepTimeout: TimeInterval = 10

    /// Smallest frame side the encoder produces a playable file for. No real window is
    /// near it; it guards frames built from hostile or degenerate geometry.
    static let minimumDimension = 16

    /// `endingAt` is when the last frame stops showing, when the caller knows it: the
    /// capture time of the frame that starts the next segment, so the two meet exactly.
    /// Otherwise the last frame is held one nominal frame interval.
    static func encode(
        frames: [CapturedFrame],
        options: ReplayOptions,
        to url: URL,
        endingAt end: Date? = nil
    ) throws -> EncodedVideo {
        guard let first = frames.first else { throw VideoEncoderError.noFrames }

        let size = first.size
        let width = Int(size.width)
        let height = Int(size.height)
        // Below this H.264 writes a file with no decodable samples and reports success.
        guard width >= minimumDimension, height >= minimumDimension else {
            throw VideoEncoderError.writerSetupFailed("frame size \(width)x\(height) is too small to encode")
        }
        let frameRate = min(10, max(1, options.frameRate))
        let times = presentationTimes(for: frames.map(\.timestamp), frameRate: frameRate, endingAt: end)

        try? FileManager.default.removeItem(at: url)

        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw VideoEncoderError.writerSetupFailed(error.localizedDescription)
        }

        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: options.quality.bitrate,
                    // One keyframe per segment. Segments are played independently, so
                    // every segment must open with an IDR frame or the first frames
                    // decode to nothing.
                    AVVideoMaxKeyFrameIntervalKey: max(1, frames.count),
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false
        // The default 1/600 s timescale rounds millisecond timestamps, pushing frames
        // captured close together off their capture times.
        input.mediaTimeScale = 1000

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )

        guard writer.canAdd(input) else {
            throw VideoEncoderError.writerSetupFailed("writer rejected the video input")
        }
        writer.add(input)
        writer.movieTimeScale = 1000

        guard writer.startWriting() else {
            throw VideoEncoderError.writerSetupFailed(
                writer.error?.localizedDescription ?? "startWriting returned false"
            )
        }
        writer.startSession(atSourceTime: .zero)

        guard let pool = adaptor.pixelBufferPool else {
            writer.cancelWriting()
            throw VideoEncoderError.pixelBufferPoolUnavailable
        }

        var written = 0
        for (index, frame) in frames.enumerated() {
            guard let buffer = pixelBuffer(from: frame, pool: pool, size: size) else { continue }

            // Polled rather than driven by `requestMediaDataWhenReady`: this runs on a
            // dedicated serial queue with a bounded frame count, so blocking is contained.
            // The status check and deadline are what keep a dead writer from spinning here
            // forever, which is the one outcome worse than a lost segment.
            let deadline = Date().addingTimeInterval(stepTimeout)
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else {
                    throw VideoEncoderError.encodeFailed(
                        writer.error?.localizedDescription ?? "writer stopped at frame \(index)"
                    )
                }
                guard Date() < deadline else {
                    writer.cancelWriting()
                    throw VideoEncoderError.timedOut("input not ready at frame \(index)")
                }
                Thread.sleep(forTimeInterval: 0.005)
            }

            if !adaptor.append(buffer, withPresentationTime: times.frames[index]) {
                writer.cancelWriting()
                throw VideoEncoderError.encodeFailed(
                    writer.error?.localizedDescription ?? "append failed at frame \(index)"
                )
            }
            written += 1
        }

        guard written > 0 else {
            writer.cancelWriting()
            throw VideoEncoderError.encodeFailed("no frame decoded")
        }

        input.markAsFinished()
        writer.endSession(atSourceTime: times.end)

        let finished = DispatchSemaphore(value: 0)
        writer.finishWriting { finished.signal() }
        if finished.wait(timeout: .now() + stepTimeout) == .timedOut {
            writer.cancelWriting()
            throw VideoEncoderError.timedOut("finishWriting did not complete")
        }

        if writer.status != .completed {
            throw VideoEncoderError.encodeFailed(
                writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
            )
        }

        // `fileSizeKey`, not `attributesOfItem`: Apple lists the latter as a required-reason
        // file-timestamp API whatever attribute is read.
        let byteSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0

        return EncodedVideo(
            url: url,
            byteSize: byteSize,
            width: width,
            height: height,
            frameCount: written,
            frameRate: frameRate,
            duration: times.end.seconds,
            start: first.timestamp
        )
    }

    /// Millisecond presentation times for frames captured at `timestamps`, plus the time
    /// the last one stops showing.
    ///
    /// Strictly increasing whatever the input: a wall clock can step backwards (an NTP
    /// correction, a user changing the time) and AVAssetWriter fails the whole segment on
    /// one non-increasing sample.
    static func presentationTimes(
        for timestamps: [Date],
        frameRate: Int,
        endingAt end: Date? = nil
    ) -> (frames: [CMTime], end: CMTime) {
        let frameMs = Int64(1000 / max(1, frameRate))
        guard let origin = timestamps.first else {
            return ([], CMTime(value: frameMs, timescale: 1000))
        }
        var values: [Int64] = []
        values.reserveCapacity(timestamps.count)
        var previous: Int64 = -1
        for timestamp in timestamps {
            let elapsed = timestamp.timeIntervalSince(origin) * 1000
            let raw = elapsed.isFinite ? Int64(max(0, min(elapsed, 86_400_000)).rounded()) : 0
            let value = max(raw, previous + 1)
            values.append(value)
            previous = value
        }
        let frames = values.map { CMTime(value: $0, timescale: 1000) }
        var endValue = previous + frameMs
        if let end {
            let elapsed = end.timeIntervalSince(origin) * 1000
            if elapsed.isFinite {
                // At least one millisecond of display, at most the nominal hold plus a
                // second: a boundary far in the future means a stalled capture, not a frame
                // that was on screen that long.
                endValue = max(previous + 1, min(Int64(elapsed.rounded()), previous + frameMs + 1000))
            }
        }
        return (frames, CMTime(value: endValue, timescale: 1000))
    }

    private static func pixelBuffer(
        from frame: CapturedFrame,
        pool: CVPixelBufferPool,
        size: CGSize
    ) -> CVPixelBuffer? {
        guard let image = UIImage(data: frame.jpeg)?.cgImage else { return nil }

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let buffer = out else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // Aspect-fit on black. Callers split segments on size changes, so this only
        // matters for a JPEG whose decoded size disagrees with its frame, where a
        // letterbox beats a stretch.
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(image, in: aspectFit(CGSize(width: image.width, height: image.height), in: size))
        return buffer
    }

    static func aspectFit(_ content: CGSize, in bounds: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: bounds) }
        let scale = min(bounds.width / content.width, bounds.height / content.height)
        let fitted = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
