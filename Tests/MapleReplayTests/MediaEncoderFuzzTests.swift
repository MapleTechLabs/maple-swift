import AVFoundation
import UIKit
import XCTest
@testable import MapleReplay

/// `VideoEncoder.encode` with random sizes, frame counts, frame rates and hostile clocks,
/// checked by decoding the MP4 it wrote.
final class MediaEncoderFuzzTests: XCTestCase {
    private static let colors = MediaFuzzVideo.palette

    func testRandomSegmentsDecodeFrameForFrame() throws {
        for seed in PrivacyFuzzConfig.seeds(default: 6, slowDivisor: 10) {
            var rng = PrivacyFuzzRNG(seed: seed)
            // From 16 px: smaller sizes are a known failure owned by the tiny-size test.
            let size = rng.chance(0.7)
                ? CGSize(width: 2 * rng.int(8...100), height: 2 * rng.int(8...100))
                : CGSize(width: 2 * rng.int(100...400), height: 2 * rng.int(100...874))
            let count = rng.int(1...40)
            let frameRate = rng.int(1...10)
            // A different-size frame is letterboxed, not split, at this layer.
            let oddOneOut = rng.chance(0.15) ? rng.int(0...(count - 1)) : nil
            let plan = (0..<count).map { index -> (Int, CGSize) in
                let size = index == oddOneOut ? CGSize(width: max(16, size.width / 2 + 2 - (size.width / 2).truncatingRemainder(dividingBy: 2)), height: size.height + 4) : size
                return (index % Self.colors.count, size)
            }
            let timestamps = randomClock(&rng, count: count, frameRate: frameRate)
            // The track takes the first frame's size, whichever frame is the odd one out.
            try check(plan: plan, timestamps: timestamps, frameRate: frameRate, size: plan[0].1, seed: seed)
        }
    }

    /// The encoder's own guard is 2x2 and the painter's floor is 2 px, but below ~15 px a
    /// side the H.264 writer finishes "successfully" with a file that has no decodable
    /// sample. Odd sizes from 15 px up decode fine here. A segment must decode or throw.
    func testTinyAndOddSizesEncodeCorrectlyOrThrow() throws {
        let sizes = [CGSize(width: 2, height: 2), CGSize(width: 3, height: 3), CGSize(width: 2, height: 5),
                     CGSize(width: 4, height: 6), CGSize(width: 8, height: 8), CGSize(width: 14, height: 14),
                     CGSize(width: 2, height: 400), CGSize(width: 400, height: 2), CGSize(width: 15, height: 15),
                     CGSize(width: 16, height: 16), CGSize(width: 101, height: 77), CGSize(width: 393, height: 851)]
        for (index, size) in sizes.enumerated() {
            let plan = (0..<4).map { ($0 % Self.colors.count, size) }
            let start = Date()
            let timestamps = (0..<4).map { start.addingTimeInterval(Double($0)) }
            let outcome = try encode(plan: plan, timestamps: timestamps, frameRate: 1)
            switch outcome {
            case .success(let video):
                let decoded = try MediaFuzzVideo.decode(video.url)
                                XCTAssertEqual(decoded.pts.count, video.frameCount, "\(size): encode succeeded but the MP4 has \(decoded.pts.count) decodable samples")
                assertColors(decoded.centers, plan: plan, context: "size \(size) case \(index)")
            case .failure(let error):
                // Refusing is only allowed below the size H.264 can write a playable file for.
                XCTAssertTrue(Int(size.width) < VideoEncoder.minimumDimension || Int(size.height) < VideoEncoder.minimumDimension,
                              "\(size) must encode, but threw \(error)")
            }
        }
    }

    /// Frames under 2 ms apart (duplicate timestamps, a clock stepping back) are spaced
    /// 1 ms apart by `presentationTimes`, but the writer's default video timescale is 600,
    /// so the MP4 cannot hold them and the muxer nudges them by up to a few ms.
    func testPresentationTimesSurviveMuxingExactly() throws {
        let start = Date()
        let timestamps = [0, 0, 0, 0, 0, 0, 0.5].map { start.addingTimeInterval($0) }
        let plan = timestamps.indices.map { ($0 % Self.colors.count, CGSize(width: 64, height: 64)) }
        guard case .success(let video) = try encode(plan: plan, timestamps: timestamps, frameRate: 1) else {
            return XCTFail("encode threw")
        }
        let decoded = try MediaFuzzVideo.decode(video.url)
        // Stated from the input, not from `presentationTimes`: duplicates step 1 ms apart,
        // and the half-second gap is kept.
        XCTAssertEqual(decoded.pts.map { Int(($0.seconds * 1000).rounded()) }, [0, 1, 2, 3, 4, 5, 500])
    }

    // MARK: - Oracle

    private func check(
        plan: [(color: Int, size: CGSize)], timestamps: [Date], frameRate: Int, size: CGSize, seed: UInt64
    ) throws {
        let context = "\(PrivacyFuzzConfig.describe(seed)) size=\(size) frames=\(plan.count) fps=\(frameRate) "
            + "offsets=\(timestamps.map { (($0.timeIntervalSince(timestamps[0])) * 1000).rounded() })"
        let video: EncodedVideo
        switch try encode(plan: plan, timestamps: timestamps, frameRate: frameRate) {
        case .success(let encoded): video = encoded
        case .failure(let error): return XCTFail("encode threw \(error). \(context)")
        }
        defer { try? FileManager.default.removeItem(at: video.url) }

        XCTAssertEqual(video.frameCount, plan.count, context)
        XCTAssertEqual(CGSize(width: video.width, height: video.height), size, context)
        let decoded = try MediaFuzzVideo.decode(video.url)
        XCTAssertEqual(decoded.naturalSize, size, "track size. \(context)")
        XCTAssertEqual(decoded.pts.count, video.frameCount, "decoded sample count. \(context)")

        let expected = VideoEncoder.presentationTimes(for: timestamps, frameRate: min(10, max(1, frameRate))).frames
        // Within a few ms, not exact: the track's timescale quantises to 1/600 s, which
        // `testPresentationTimesSurviveMuxingExactly` pins on its own.
        XCTAssertEqual(decoded.pts.count, expected.count, "presentation times. \(context)")
        // Each pair under 2 ms apart can push every later sample by up to ~1.7 ms more.
        let closePairs = zip(expected, expected.dropFirst()).filter { ($1 - $0).seconds < 0.002 }.count
        let slack = 0.002 + 0.002 * Double(closePairs)
        for (index, (got, want)) in zip(decoded.pts, expected).enumerated() where abs(got.seconds - want.seconds) > slack {
            XCTFail("frame \(index) presented at \(got.seconds) s, encoder computed \(want.seconds) s. \(context)")
            break
        }
        for (a, b) in zip(decoded.pts, decoded.pts.dropFirst()) where b <= a {
            XCTFail("presentation times not strictly increasing: \(a.seconds) then \(b.seconds). \(context)")
        }
        XCTAssertEqual(decoded.duration, video.duration, accuracy: 0.002, "asset duration. \(context)")
        assertColors(decoded.centers, plan: plan, context: context)
    }

    func assertColors(_ centers: [(r: Int, g: Int, b: Int)], plan: [(color: Int, size: CGSize)], context: String) {
        for (index, (center, step)) in zip(centers, plan).enumerated() {
            let want = Self.colors[step.color]
            // Nearest palette colour, not a fixed tolerance: tiny frames at low bitrate
            // drift in chroma, but never far enough to look like another palette entry.
            let nearest = Self.colors.indices.min { a, b in
                let ca = Self.colors[a], cb = Self.colors[b]
                return abs(ca.r - center.r) + abs(ca.g - center.g) + abs(ca.b - center.b)
                    < abs(cb.r - center.r) + abs(cb.g - center.g) + abs(cb.b - center.b)
            }
            if nearest != step.color {
                XCTFail("frame \(index) centre \(center), source \(want): reordered or dropped. \(context)")
                return
            }
        }
    }

    // MARK: - Encode / decode

    private func randomClock(_ rng: inout PrivacyFuzzRNG, count: Int, frameRate: Int) -> [Date] {
        var t = Date()
        return (0..<count).map { index in
            if index > 0 {
                switch rng.int(0...9) {
                case 0: break // duplicate
                case 1: t.addTimeInterval(-rng.cgFloat(0.001...3)) // wall clock stepped back
                case 2: t.addTimeInterval(rng.cgFloat(2...12)) // multi-second stall
                case 3: t.addTimeInterval(0.0004) // sub-millisecond
                default: t.addTimeInterval(1 / Double(frameRate) + rng.cgFloat(-0.02...0.05))
                }
            }
            return t
        }
    }

    /// Runs the encode off the main thread under a deadline, so a wedged writer fails
    /// this test instead of hanging the suite.
    private func encode(plan: [(color: Int, size: CGSize)], timestamps: [Date], frameRate: Int) throws
        -> Result<EncodedVideo, Error>
    {
        let frames = zip(plan, timestamps).map { step, timestamp in
            CapturedFrame(jpeg: MediaFuzzVideo.jpeg(color: step.color, size: step.size), timestamp: timestamp,
                          size: step.size)
        }
        var options = ReplayOptions()
        options.frameRate = frameRate
        options.quality = .medium
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-fuzz-\(UUID().uuidString).mp4")
        let done = expectation(description: "encode")
        var outcome: Result<EncodedVideo, Error>?
        DispatchQueue.global().async {
            outcome = Result { try VideoEncoder.encode(frames: frames, options: options, to: url) }
            done.fulfill()
        }
        // Two step timeouts plus slack: anything longer means a wait the encoder lost track of.
        wait(for: [done], timeout: VideoEncoder.stepTimeout * 2 + 10)
        return try XCTUnwrap(outcome, "encode of \(frames.count) frames at \(plan.first?.size ?? .zero) never returned")
    }
}

/// Decoding helpers shared by the Media fuzzers.
enum MediaFuzzVideo {
    /// Distinct, saturated colours, so codec loss cannot turn one into its neighbour.
    static let palette: [(r: Int, g: Int, b: Int)] = [
        (230, 20, 20), (20, 200, 40), (30, 40, 230), (240, 230, 30), (20, 210, 220), (240, 240, 240),
    ]

    static func jpeg(color index: Int, size: CGSize) -> Data {
        let c = palette[index]
        let color = UIColor(red: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: 1)
        return PrivacyFuzzPalette.solidImage(color, size: size).jpegData(compressionQuality: 0.9)!
    }

    struct Decoded {
        var naturalSize: CGSize
        var duration: TimeInterval
        var pts: [CMTime]
        var centers: [(r: Int, g: Int, b: Int)]
    }

    static func decode(_ url: URL) throws -> Decoded {
        let asset = AVURLAsset(url: url)
        let track = try XCTUnwrap(asset.tracks(withMediaType: .video).first, "no video track in \(url.lastPathComponent)")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        reader.add(output)
        XCTAssertTrue(reader.startReading(), "reader: \(String(describing: reader.error))")
        var result = Decoded(naturalSize: track.naturalSize, duration: asset.duration.seconds, pts: [], centers: [])
        while let sample = output.copyNextSampleBuffer() {
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            result.pts.append(CMSampleBufferGetPresentationTimeStamp(sample))
            if let buffer = CMSampleBufferGetImageBuffer(sample) { result.centers.append(center(of: buffer)) }
        }
        XCTAssertEqual(reader.status, .completed, "\(url.lastPathComponent): \(String(describing: reader.error))")
        return result
    }

    private static func center(of buffer: CVPixelBuffer) -> (r: Int, g: Int, b: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let pixel = base.advanced(by: (CVPixelBufferGetHeight(buffer) / 2) * row + (CVPixelBufferGetWidth(buffer) / 2) * 4)
            .assumingMemoryBound(to: UInt8.self)
        return (Int(pixel[2]), Int(pixel[1]), Int(pixel[0]))
    }

    /// Index of the palette colour nearest `rgb`, or nil if none is within codec tolerance.
    static func paletteIndex(of rgb: (r: Int, g: Int, b: Int)) -> Int? {
        palette.indices.first { i in
            let c = palette[i]
            return max(abs(c.r - rgb.r), abs(c.g - rgb.g), abs(c.b - rgb.b)) <= 60
        }
    }
}
