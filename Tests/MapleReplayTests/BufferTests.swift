import XCTest
@testable import MapleReplay

final class FrameRingBufferTests: XCTestCase {
    private func frame(at offset: TimeInterval, bytes: Int = 10) -> CapturedFrame {
        CapturedFrame(
            jpeg: Data(repeating: 0xAB, count: bytes),
            timestamp: Date(timeIntervalSince1970: 1_000 + offset),
            size: CGSize(width: 100, height: 200)
        )
    }

    func testEvictsOldestOnOverflow() {
        let buffer = FrameRingBuffer(capacity: 3)
        for index in 0..<5 { buffer.append(frame(at: TimeInterval(index))) }

        XCTAssertEqual(buffer.count, 3)
        // Frames 0 and 1 evicted; the window slid forward.
        XCTAssertEqual(buffer.frames.first?.timestamp, Date(timeIntervalSince1970: 1_002))
        XCTAssertEqual(buffer.frames.last?.timestamp, Date(timeIntervalSince1970: 1_004))
    }

    func testCapacityCoversRequestedWindowWithHeadroom() {
        // 30 s at 1 fps needs 30 frames, plus one slot so a boundary landing mid-frame
        // doesn't evict the frame that completes the window.
        XCTAssertEqual(FrameRingBuffer.capacity(forSeconds: 30, frameRate: 1), 31)
        XCTAssertEqual(FrameRingBuffer.capacity(forSeconds: 5, frameRate: 2), 11)
        // Fractional windows round up rather than truncating a partial frame away.
        XCTAssertEqual(FrameRingBuffer.capacity(forSeconds: 2.5, frameRate: 1), 4)
        // Degenerate inputs still yield a usable buffer.
        XCTAssertEqual(FrameRingBuffer.capacity(forSeconds: 0, frameRate: 0), 1)
    }

    func testDrainEmptiesAndReturnsEverything() {
        let buffer = FrameRingBuffer(capacity: 10)
        for index in 0..<4 { buffer.append(frame(at: TimeInterval(index))) }

        let drained = buffer.drain()
        XCTAssertEqual(drained.count, 4)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testResizeTrimsToNewestFrames() {
        let buffer = FrameRingBuffer(capacity: 10)
        for index in 0..<6 { buffer.append(frame(at: TimeInterval(index))) }

        buffer.resize(capacity: 2)
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.frames.first?.timestamp, Date(timeIntervalSince1970: 1_004))
    }

    func testDurationAndByteSize() {
        let buffer = FrameRingBuffer(capacity: 10)
        buffer.append(frame(at: 0, bytes: 100))
        buffer.append(frame(at: 5, bytes: 150))

        XCTAssertEqual(buffer.duration, 5)
        XCTAssertEqual(buffer.byteSize, 250)
    }
}

final class FlushPolicyTests: XCTestCase {
    func testRetainedSecondsDrivesBufferSizing() {
        XCTAssertEqual(FlushPolicy.continuous(segmentDuration: 5).retainedSeconds, 5)
        XCTAssertEqual(FlushPolicy.buffered(window: 30).retainedSeconds, 30)
    }

    func testDefaultsMatchTheDocumentedContract() {
        XCTAssertEqual(FlushPolicy.defaultContinuous, .continuous(segmentDuration: 5))
        XCTAssertEqual(FlushPolicy.defaultBuffered, .buffered(window: 30))
    }

    func testBufferedWindowNeedsSixTimesTheContinuousCapacity() {
        // The two policies share one buffer; only its capacity differs. This is the
        // property that lets error-triggered capture exist without a second code path.
        let continuous = FrameRingBuffer.capacity(
            forSeconds: FlushPolicy.defaultContinuous.retainedSeconds, frameRate: 1
        )
        let buffered = FrameRingBuffer.capacity(
            forSeconds: FlushPolicy.defaultBuffered.retainedSeconds, frameRate: 1
        )
        XCTAssertEqual(continuous, 6)
        XCTAssertEqual(buffered, 31)
    }
}
