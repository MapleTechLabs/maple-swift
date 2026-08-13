import Foundation
import UIKit

/// Drives capture, buffering, and segment emission.
///
/// Threading contract:
///  - Capture and view-tree scanning run on the **main thread** (UIKit requires it).
///  - Redaction, compression, buffering, and encoding run on `workQueue`, a serial queue.
///
/// The unredacted `UIImage` exists only in the hop between the two, and is never retained
/// or written. That hop is unavoidable — you cannot redact what you have not yet captured.
final class ReplayRecorder {
    private let options: ReplayOptions
    private let sessionId: String
    private let writer: SegmentWriter
    private let touches = TouchTracker()
    private let touchObserver: TouchObserver

    private let workQueue = DispatchQueue(label: "dev.maple.replay.work", qos: .utility)
    private var buffer: FrameRingBuffer
    private var timer: DispatchSourceTimer?

    private var chunkSeq = 0
    private var segmentStart: Date?
    private var isRunning = false

    /// Segments produced so far. Milestone 1 keeps these for inspection; milestone 2
    /// replaces this with an upload queue.
    private(set) var artifacts: [SegmentArtifacts] = []

    var onSegment: ((SegmentArtifacts) -> Void)?

    init(sessionId: String, options: ReplayOptions) {
        self.sessionId = sessionId
        self.options = options
        self.touchObserver = TouchObserver(tracker: touches)
        self.buffer = FrameRingBuffer(
            capacity: FrameRingBuffer.capacity(
                forSeconds: options.flushPolicy.retainedSeconds,
                frameRate: options.frameRate
            )
        )
        let root = options.outputDirectory ?? Self.defaultOutputDirectory()
        self.writer = SegmentWriter(
            directory: root.appendingPathComponent(sessionId, isDirectory: true),
            sessionId: sessionId
        )
    }

    static func defaultOutputDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("maple-replay", isDirectory: true)
    }

    var outputDirectory: URL { writer.directory }

    // MARK: - Lifecycle

    @MainActor
    func start() {
        guard !isRunning else { return }
        isRunning = true
        segmentStart = Date()

        if let window = ViewCapture.activeWindow() {
            touchObserver.attach(to: window)
        }

        // A DispatchSourceTimer rather than a Timer: an NSTimer scheduled in the default
        // run-loop mode stops firing while a scroll view is tracking, which would silently
        // drop every frame during exactly the interactions worth recording.
        let interval = 1.0 / Double(max(1, options.frameRate))
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        isRunning = false
        timer?.cancel()
        timer = nil
        touchObserver.detach()
    }

    // MARK: - Capture

    private func tick() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            guard let pending = ViewCapture.capture(options: self.options) else { return }
            self.workQueue.async { self.ingest(pending) }
        }
    }

    private func ingest(_ pending: PendingFrame) {
        guard let frame = RedactionPainter.redactAndCompress(pending, options: options) else { return }
        buffer.append(frame)

        if case .continuous(let segmentDuration) = options.flushPolicy {
            let start = segmentStart ?? frame.timestamp
            if frame.timestamp.timeIntervalSince(start) >= segmentDuration {
                emitSegment(reason: "interval")
            }
        }
    }

    // MARK: - Flush

    /// Emit whatever is buffered. This is the seam error-triggered capture hangs off:
    /// in buffered mode nothing is written until someone calls this.
    func flush(trigger: String) {
        workQueue.async { [weak self] in
            self?.emitSegment(reason: trigger)
        }
    }

    /// Must run on `workQueue`.
    private func emitSegment(reason: String) {
        let frames = buffer.drain()
        guard !frames.isEmpty else { return }

        let seq = chunkSeq
        chunkSeq += 1
        let start = frames.first?.timestamp ?? Date()
        let end = frames.last?.timestamp ?? start
        segmentStart = Date()

        do {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("maple-segment-\(seq)-\(UUID().uuidString).mp4")
            let video = try VideoEncoder.encode(frames: frames, options: options, to: temporaryURL)

            var events: [RRWebEvent] = [
                .meta(
                    timestamp: start,
                    width: video.width,
                    height: video.height,
                    href: "maple://replay/\(sessionId)"
                ),
                .video(
                    timestamp: start,
                    segmentId: seq,
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
            events.append(contentsOf: touches.drain(until: end))
            events.sort { $0.timestamp < $1.timestamp }

            // Every segment stands alone: it opens with a meta event and an IDR-keyframed
            // video, so any segment is a valid seek target. On the web side that is what
            // `is_checkpoint` marks, so every mobile chunk is a checkpoint.
            let artifact = try writer.write(
                video: video, events: events, chunkSeq: seq, isCheckpoint: true
            )
            artifacts.append(artifact)
            onSegment?(artifact)
        } catch {
            NSLog("[MapleReplay] segment \(seq) failed: \(error)")
        }
    }
}
