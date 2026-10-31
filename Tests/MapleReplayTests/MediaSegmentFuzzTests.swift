import AVFoundation
import UIKit
import XCTest
@testable import MapleReplay

/// Segment splitting under rotation: random frame sequences whose size changes, fed
/// straight into `ReplayRecorder.ingest`, emitted by flushes and by the interval rule.
final class MediaSegmentFuzzTests: XCTestCase {
    private static let sizes = [CGSize(width: 64, height: 128), CGSize(width: 128, height: 64), CGSize(width: 96, height: 96)]

    func testSegmentsHaveOneSizeAndPartitionTheFramesInOrder() throws {
        var totals = (segments: 0, triggers: 0, splits: 0)
        for seed in PrivacyFuzzConfig.seeds(default: 4, slowDivisor: 10) {
            let run = try runOnce(seed: seed)
            totals = (totals.segments + run.segments, totals.triggers + run.triggers, totals.splits + run.splits)
        }
        XCTAssertGreaterThan(totals.segments, 0, "no segment was emitted: nothing was checked")
        XCTAssertGreaterThan(totals.splits, 0, "no flush ever spanned a size change: splitting was not exercised")
    }

    private func runOnce(seed: UInt64) throws -> (segments: Int, triggers: Int, splits: Int) {
        var rng = PrivacyFuzzRNG(seed: seed)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-segment-fuzz-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        var options = ReplayOptions()
        options.crashRecovery = false
        options.outputDirectory = directory
        options.writeSegmentsToDisk = true
        options.frameRate = 10
        options.quality = .low
        // One-second segments at 10 fps: an 11-frame ring, so a batch of up to 11 frames
        // between emissions is never evicted and the partition must be exact.
        let recorder = ReplayRecorder(sessionId: "fuzz-\(seed)", options: options, capture: .continuous(segmentDuration: 1))
        let lock = NSLock()
        var emitted: [SegmentArtifacts] = []
        recorder.onSegment = { segment in
            lock.lock(); emitted.append(segment.artifacts); lock.unlock()
        }

        // Frames are stamped 0.1 s apart in the past, so only a frame stamped 5 s ahead of
        // the wall clock crosses the one-second boundary.
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        var expected: [(size: CGSize, colors: [Int])] = []
        var pending: [(size: CGSize, color: Int)] = []
        var log: [String] = []
        var size = rng.pick(Self.sizes)
        var counter = 0
        var segmentStartSet = false
        var triggers = 0
        var splits = 0

        for _ in 0..<rng.int(1...6) {
            let count = rng.int(0...10)
            for index in 0..<count {
                if rng.chance(0.3) { size = rng.pick(Self.sizes) }
                let trigger = segmentStartSet && index == count - 1 && rng.chance(0.3)
                let color = counter % MediaFuzzVideo.palette.count
                let timestamp = trigger ? Date().addingTimeInterval(5) : past.addingTimeInterval(Double(counter) * 0.1)
                recorder.ingest(CapturedFrame(jpeg: MediaFuzzVideo.jpeg(color: color, size: size), timestamp: timestamp, size: size))
                counter += 1
                pending.append((size, color))
                log.append("\(Int(size.width))x\(Int(size.height))\(trigger ? "!" : "")")
                if trigger {
                    // The late frame closes the segment before it and opens the next one.
                    let closing = Array(pending.dropLast())
                    if !closing.isEmpty {
                        triggers += 1
                        splits += max(0, Self.runs(closing).count - 1)
                        expected += Self.runs(closing)
                        pending = Array(pending.suffix(1))
                    }
                }
            }
            recorder.flush(trigger: "fuzz")
            recorder.drainQueue()
            log.append("|")
            splits += max(0, Self.runs(pending).count - 1)
            expected += Self.runs(pending)
            pending = []
            segmentStartSet = true
        }

        lock.lock(); let segments = emitted; lock.unlock()
        let context = "\(PrivacyFuzzConfig.describe(seed)) frames (| = flush, ! = interval trigger): \(log.joined(separator: " "))"
        XCTAssertEqual(segments.map(\.chunkSeq), Array(0..<expected.count), "chunk seqs. \(context)")
        for (index, (segment, want)) in zip(segments, expected).enumerated() {
            let where_ = "segment \(index) (seq \(segment.chunkSeq)). \(context)"
            XCTAssertEqual(segment.frameCount, want.colors.count, "frame count, \(where_)")
            let url = try XCTUnwrap(segment.videoURL, "no video written, \(where_)")
            let decoded = try MediaFuzzVideo.decode(url)
            XCTAssertEqual(decoded.naturalSize, want.size, "track size, \(where_)")
            XCTAssertEqual(decoded.centers.map(MediaFuzzVideo.paletteIndex), want.colors.map { Optional($0) },
                           "decoded frame order, \(where_)")
        }
        return (segments.count, triggers, splits)
    }

    /// The expected split: consecutive frames of one size each.
    private static func runs(_ frames: [(size: CGSize, color: Int)]) -> [(size: CGSize, colors: [Int])] {
        var runs: [(size: CGSize, colors: [Int])] = []
        for frame in frames {
            if let last = runs.last, last.size == frame.size {
                runs[runs.count - 1].colors.append(frame.color)
            } else {
                runs.append((frame.size, [frame.color]))
            }
        }
        return runs
    }
}
