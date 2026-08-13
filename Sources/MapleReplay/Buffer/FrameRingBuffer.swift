import Foundation
import CoreGraphics

/// One captured, already-redacted frame.
///
/// Frames are held as JPEG `Data`, never as `UIImage` or `CVPixelBuffer`. At 30 s of
/// buffered capture on a 3x phone, raw ARGB would be several hundred megabytes; JPEG at
/// the configured quality is two orders of magnitude smaller. Compression happens on the
/// capture queue immediately after redaction, so nothing unredacted is ever retained.
struct CapturedFrame {
    let jpeg: Data
    let timestamp: Date
    let size: CGSize
}

/// Fixed-capacity FIFO that evicts the oldest frame on overflow.
///
/// Not thread-safe by itself — `ReplayRecorder` confines all access to its capture queue.
final class FrameRingBuffer {
    private(set) var frames: [CapturedFrame] = []
    private(set) var capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
        frames.reserveCapacity(self.capacity)
    }

    /// Frames needed to cover `seconds` at `frameRate`, with one slot of headroom so a
    /// boundary landing mid-frame doesn't drop the frame that completes the window.
    static func capacity(forSeconds seconds: TimeInterval, frameRate: Int) -> Int {
        max(1, Int((seconds * Double(max(1, frameRate))).rounded(.up)) + 1)
    }

    var count: Int { frames.count }
    var isEmpty: Bool { frames.isEmpty }

    var byteSize: Int {
        frames.reduce(0) { $0 + $1.jpeg.count }
    }

    /// Wall-clock span covered by the buffered frames.
    var duration: TimeInterval {
        guard let first = frames.first, let last = frames.last, frames.count > 1 else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp)
    }

    func append(_ frame: CapturedFrame) {
        frames.append(frame)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    func resize(capacity newCapacity: Int) {
        capacity = max(1, newCapacity)
        if frames.count > capacity {
            frames.removeFirst(frames.count - capacity)
        }
    }

    /// Remove and return everything currently buffered.
    func drain() -> [CapturedFrame] {
        defer { frames.removeAll(keepingCapacity: true) }
        return frames
    }

    func removeAll() {
        frames.removeAll(keepingCapacity: true)
    }
}
