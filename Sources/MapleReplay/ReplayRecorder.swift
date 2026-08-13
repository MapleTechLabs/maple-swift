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
    /// Disk mirror of `buffer`. Nil when crash recovery is disabled.
    private let spool: FrameSpool?
    private var timer: DispatchSourceTimer?

    private var chunkSeq = 0
    private var segmentStart: Date?
    private var isRunning = false

    /// Segments produced so far, for inspection. Only the records — the bodies are
    /// handed to `onSegment` and released, so a long session does not accumulate every
    /// chunk it ever uploaded in memory.
    private(set) var artifacts: [SegmentArtifacts] = []

    /// Called on `workQueue` as each segment is prepared, with the bytes to upload.
    var onSegment: ((PreparedSegment) -> Void)?

    init(
        sessionId: String,
        options: ReplayOptions,
        startedAt: Date = Date(),
        serviceName: String = "ios-app",
        environment: String? = nil,
        userId: String = ""
    ) {
        self.sessionId = sessionId
        self.options = options
        self.touchObserver = TouchObserver(tracker: touches)
        let capacity = FrameRingBuffer.capacity(
            forSeconds: options.flushPolicy.retainedSeconds,
            frameRate: options.frameRate
        )
        self.buffer = FrameRingBuffer(capacity: capacity)

        let root = Self.rootDirectory(options: options)
        self.writer = SegmentWriter(
            directory: root.appendingPathComponent(sessionId, isDirectory: true),
            sessionId: sessionId,
            persistToDisk: options.writeSegmentsToDisk
        )

        self.spool = options.crashRecovery
            ? FrameSpool(
                root: root,
                manifest: SpoolManifest(
                    sessionId: sessionId,
                    startedAt: startedAt.timeIntervalSince1970,
                    frameRate: options.frameRate,
                    quality: options.quality.rawValue,
                    serviceName: serviceName,
                    environment: environment,
                    userId: userId,
                    nextChunkSeq: 0,
                    recoveryAttempts: 0
                ),
                capacity: capacity,
                byteBudget: options.maxSpoolBytes
            )
            : nil
    }

    static func defaultOutputDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("maple-replay", isDirectory: true)
    }

    /// Directory holding every session's output and the shared `spool/`.
    static func rootDirectory(options: ReplayOptions) -> URL {
        options.outputDirectory ?? defaultOutputDirectory()
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

        // Queued behind any in-flight flush, so the spool outlives the frames it is
        // protecting and is deleted only once they have been written as a segment.
        // Deleting it here is what makes a surviving spool mean "this session crashed".
        workQueue.async { [spool] in spool?.remove() }
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
        // The frame reaching the spool is the same object the buffer holds — already
        // redacted and compressed by the painter above. There is no path by which an
        // unredacted frame reaches disk.
        spool?.append(frame)

        if case .continuous(let segmentDuration) = options.flushPolicy {
            let start = segmentStart ?? frame.timestamp
            if frame.timestamp.timeIntervalSince(start) >= segmentDuration {
                emitSegment(reason: "interval")
            }
        }
    }

    // MARK: - Flush

    /// Emit whatever is buffered. This is the seam error-triggered capture hangs off:
    /// in buffered mode nothing is emitted until someone calls this.
    ///
    /// `completion` runs on `workQueue` once the segment has been prepared and handed to
    /// `onSegment` — which is where its upload starts, not where it finishes. Waiting for
    /// the network is the transport's job.
    func flush(trigger: String, completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            self?.emitSegment(reason: trigger)
            completion?()
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

        // Drop the disk copy at the same moment the buffer is drained, before encoding
        // rather than after. The two copies then fail identically: a crash during encode
        // loses the segment from memory and disk alike. Clearing after a successful write
        // would instead leave a window in which recovery re-emits a segment that was
        // already emitted, under a sequence number that is now taken.
        spool?.clearFrames(nextChunkSeq: chunkSeq)

        do {
            let temporaryURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("maple-segment-\(seq)-\(UUID().uuidString).mp4")
            let video = try VideoEncoder.encode(frames: frames, options: options, to: temporaryURL)

            let events = SegmentEvents.build(
                sessionId: sessionId,
                chunkSeq: seq,
                video: video,
                start: start,
                reason: reason,
                extra: touches.drain(until: end)
            )

            // Every segment stands alone: it opens with a meta event and an IDR-keyframed
            // video, so any segment is a valid seek target. On the web side that is what
            // `is_checkpoint` marks, so every mobile chunk is a checkpoint.
            let segment = try writer.prepare(
                video: video, events: events, chunkSeq: seq, isCheckpoint: true
            )
            artifacts.append(segment.artifacts)
            onSegment?(segment)
        } catch {
            NSLog("[MapleReplay] segment \(seq) failed: \(error)")
        }
    }
}
