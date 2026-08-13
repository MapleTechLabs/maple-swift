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
}

/// Encodes buffered JPEG frames into an H.264/MP4 segment via AVAssetWriter.
///
/// Constant frame rate: presentation times are derived from the frame index and the
/// configured rate rather than from wall-clock capture timestamps. The declared wire
/// format says `frameRateType: "constant"`, and a player that trusts that field will
/// desynchronise if we emit variable timings. Real capture jitter at 1 fps is well under
/// one frame, so nothing is lost.
enum VideoEncoder {
    static func encode(
        frames: [CapturedFrame],
        options: ReplayOptions,
        to url: URL
    ) throws -> EncodedVideo {
        guard let first = frames.first else { throw VideoEncoderError.noFrames }

        let size = first.size
        let width = Int(size.width)
        let height = Int(size.height)
        let frameRate = max(1, options.frameRate)

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
                    AVVideoMaxKeyFrameIntervalKey: frames.count,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264BaselineAutoLevel,
                ],
            ]
        )
        input.expectsMediaDataInRealTime = false

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

        for (index, frame) in frames.enumerated() {
            guard let buffer = pixelBuffer(from: frame, pool: pool, size: size) else { continue }

            // Spin rather than using the async callback API: this runs on a dedicated
            // serial encode queue with a bounded frame count, so blocking is contained
            // and the control flow stays legible.
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.005)
            }

            let time = CMTime(value: CMTimeValue(index), timescale: CMTimeScale(frameRate))
            if !adaptor.append(buffer, withPresentationTime: time) {
                writer.cancelWriting()
                throw VideoEncoderError.encodeFailed(
                    writer.error?.localizedDescription ?? "append failed at frame \(index)"
                )
            }
        }

        input.markAsFinished()

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()

        if writer.status != .completed {
            throw VideoEncoderError.encodeFailed(
                writer.error?.localizedDescription ?? "writer status \(writer.status.rawValue)"
            )
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let byteSize = (attributes?[.size] as? Int) ?? 0

        return EncodedVideo(
            url: url,
            byteSize: byteSize,
            width: width,
            height: height,
            frameCount: frames.count,
            frameRate: frameRate,
            duration: Double(frames.count) / Double(frameRate),
            start: first.timestamp
        )
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

        context.draw(image, in: CGRect(origin: .zero, size: size))
        return buffer
    }
}
