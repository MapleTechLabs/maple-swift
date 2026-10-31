import Foundation
import UIKit

/// Drives capture, buffering, and segment emission.
///
/// Threading contract:
///  - Capture and view-tree scanning run on the **main thread** (UIKit requires it).
///  - Redaction, compression, buffering, and encoding run on `workQueue`, a serial queue.
///
/// The unredacted `UIImage` exists only in the hop between the two, and is never retained
/// or written. That hop is unavoidable: you cannot redact what you have not yet captured.
final class ReplayRecorder {
    /// How frames become segments.
    enum Capture: Equatable {
        /// A segment every `segmentDuration` seconds.
        case continuous(segmentDuration: TimeInterval)
        /// Hold the last `window` seconds; emit only on `flush`.
        case buffered(window: TimeInterval)

        var retainedSeconds: TimeInterval {
            switch self {
            case .continuous(let duration): return duration
            case .buffered(let window): return window
            }
        }
    }

    private let options: ReplayOptions
    private let sessionId: String
    private let writer: SegmentWriter
    let touches = TouchTracker()
    let touchObserver: TouchObserver

    private let workQueue = DispatchQueue(label: "dev.maple.replay.work", qos: .utility)
    private var capture: Capture
    private var buffer: FrameRingBuffer
    /// Disk mirror of `buffer`. Nil when crash recovery is disabled.
    private let spool: FrameSpool?
    private var timer: DispatchSourceTimer?

    private let sequencer: ChunkSequencer
    /// Main thread only.
    private var isRunning = false
    /// `workQueue` only. Set while a capture is queued on or running on the main thread.
    ///
    /// When the main thread stalls, every timer tick would otherwise queue another
    /// capture, and the moment it frees up they all run back to back: a burst of full
    /// view-tree scans landing on exactly the frames after a hang.
    private var captureInFlight = false

    /// Segments produced so far, for inspection. Only the records: the bodies are handed
    /// to `onSegment` and released, so a long session does not accumulate every chunk it
    /// ever uploaded in memory.
    var artifacts: [SegmentArtifacts] {
        artifactsLock.lock(); defer { artifactsLock.unlock() }
        return artifactRecords
    }
    /// Read from any thread through `MapleReplay.segments`, appended on `workQueue`.
    private var artifactRecords: [SegmentArtifacts] = []
    private let artifactsLock = NSLock()

    /// Called on `workQueue` as each segment is prepared, with the bytes to upload.
    var onSegment: ((PreparedSegment) -> Void)?

    init(
        sessionId: String,
        options: ReplayOptions,
        capture: Capture? = nil,
        sequencer: ChunkSequencer = ChunkSequencer(),
        run: Int = 0,
        mode: ReplayMode = .record,
        startedAt: Date = Date(),
        serviceName: String = "ios-app",
        environment: String? = nil,
        userId: String = ""
    ) {
        let options = options.normalized()
        self.sessionId = sessionId
        self.options = options
        self.capture = capture ?? .continuous(segmentDuration: options.segmentDuration)
        self.sequencer = sequencer
        self.touchObserver = TouchObserver(tracker: touches, recordLocations: options.recordTouches)
        let scanner = RedactionScanner(options: options)
        touchObserver.isForcedView = { scanner.isForcedByRule($0) }
        let capacity = FrameRingBuffer.capacity(
            forSeconds: self.capture.retainedSeconds,
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
                    nextChunkSeq: sequencer.peek,
                    recoveryAttempts: 0,
                    mode: mode.rawValue
                ),
                capacity: capacity,
                byteBudget: options.maxSpoolBytes,
                run: run
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

        if let window = ViewCapture.activeWindow() {
            touchObserver.attach(to: window)
        }

        // A DispatchSourceTimer rather than a Timer: an NSTimer scheduled in the default
        // run-loop mode stops firing while a scroll view is tracking, which would silently
        // drop every frame during exactly the interactions worth recording.
        let interval = 1.0 / Double(options.frameRate)
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
        touchObserver.maskedRegions = []

        // Queued behind any in-flight flush, so the spool outlives the frames it is
        // protecting and is deleted only once they have been written as a segment.
        // Deleting it here is what makes a surviving spool mean "this session crashed".
        workQueue.async { [spool] in spool?.remove() }
    }

    // MARK: - Capture

    /// Runs on `workQueue`.
    private func tick() {
        guard !captureInFlight else { return }
        captureInFlight = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let pending = self.captureOnMain()
            self.workQueue.async {
                self.captureInFlight = false
                if let pending { self.ingest(pending) }
            }
        }
    }

    @MainActor
    private func captureOnMain() -> PendingFrame? {
        guard isRunning, let window = ViewCapture.activeWindow() else { return nil }
        // The key window changes when an app presents a window of its own; touches have
        // to follow it or they stop being recorded without any sign.
        if touchObserver.attachedWindow !== window { touchObserver.attach(to: window) }
        guard let pending = ViewCapture.capture(window: window, options: options) else { return nil }
        touchObserver.maskedRegions = pending.sensitive
        return pending
    }

    /// Feed one captured frame through redaction and into the buffer. `workQueue` only;
    /// internal so tests can drive the pipeline without a running app.
    func ingest(_ pending: PendingFrame) {
        guard let frame = RedactionPainter.redactAndCompress(pending, options: options) else { return }
        ingest(frame)
    }

    func ingest(_ frame: CapturedFrame) {
        // A frame past the boundary closes the segment before it and opens the next, so
        // the closing segment ends exactly where this frame begins: no seam replays
        // twice and none freezes.
        if case .continuous(let segmentDuration) = capture,
           let start = buffer.frames.first?.timestamp,
           frame.timestamp.timeIntervalSince(start) >= segmentDuration {
            emitSegment(reason: "interval", endingAt: frame.timestamp)
        }

        buffer.append(frame)
        // The frame reaching the spool is the same value the buffer holds, already
        // redacted and compressed. There is no path by which an unredacted frame
        // reaches disk.
        spool?.append(frame, nextChunkSeq: sequencer.peek)

        if case .buffered = capture, let oldest = buffer.frames.first?.timestamp {
            // Touches age out with the video they belong to.
            touches.discard(olderThan: oldest)
        }
    }

    // MARK: - Flush

    /// Emit whatever is buffered. In buffered mode nothing is emitted until someone calls
    /// this; error-triggered capture hangs off it.
    ///
    /// `completion` runs on `workQueue` once the segment has been prepared and handed to
    /// `onSegment`, which is where its upload starts, not where it finishes.
    func flush(trigger: String, completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            self?.emitSegment(reason: trigger)
            completion?()
        }
    }

    /// Emit the buffered window and record continuously from here on.
    ///
    /// The window is emitted before the buffer shrinks to segment size, or the resize
    /// would evict the seconds before the error, which are the reason for the flush.
    func promote(to segmentDuration: TimeInterval, trigger: String, completion: (() -> Void)? = nil) {
        workQueue.async { [weak self] in
            guard let self else { completion?(); return }
            self.emitSegment(reason: trigger)
            self.capture = .continuous(segmentDuration: segmentDuration)
            let capacity = FrameRingBuffer.capacity(forSeconds: segmentDuration, frameRate: self.options.frameRate)
            self.buffer.resize(capacity: capacity)
            self.spool?.resize(capacity: capacity)
            completion?()
        }
    }

    /// Must run on `workQueue`. `end` is the capture time of the frame that follows, when
    /// there is one.
    private func emitSegment(reason: String, endingAt end: Date? = nil) {
        let frames = buffer.drain()
        guard let first = frames.first, let last = frames.last else { return }

        let runs = frames.runsOfEqualSize()
        let firstSeq = sequencer.take(runs.count)

        // Drop the disk copy at the same moment the buffer is drained, before encoding
        // rather than after. The two copies then fail identically: a crash during encode
        // loses the segment from memory and disk alike. Clearing after a successful write
        // would instead leave a window in which recovery re-emits a segment that was
        // already emitted, under a sequence number that is now taken.
        spool?.clearFrames(nextChunkSeq: sequencer.peek)

        // Up to the end of the last frame's display, so a tap during the final second
        // belongs to this segment rather than falling before the next one's start.
        let videoEnd = end ?? last.timestamp.addingTimeInterval(1 / Double(options.frameRate))
        let touchSamples = touches.drain(until: videoEnd, notBefore: first.timestamp)

        for (index, run) in runs.enumerated() {
            let seq = firstSeq + index
            guard let start = run.first?.timestamp else { continue }
            do {
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent("maple-segment-\(seq)-\(UUID().uuidString).mp4")
                // Only the last run knows its end: earlier runs end where the next size
                // starts, which is that run's first frame.
                let runEnd = index + 1 < runs.count ? runs[index + 1].first?.timestamp : end
                let video = try VideoEncoder.encode(frames: run, options: options, to: temporaryURL, endingAt: runEnd)

                let events = SegmentEvents.build(
                    sessionId: sessionId,
                    chunkSeq: seq,
                    video: video,
                    start: start,
                    reason: reason,
                    pointSize: run.first?.pointSize,
                    touches: touchSamples
                )

                // Every segment stands alone: it opens with a meta event and an
                // IDR-keyframed video, so any segment is a valid seek target. On the web
                // side that is what `is_checkpoint` marks, so every mobile chunk is one.
                let segment = try writer.prepare(
                    video: video, events: events, chunkSeq: seq, isCheckpoint: true
                )
                artifactsLock.lock()
                artifactRecords.append(segment.artifacts)
                artifactsLock.unlock()
                onSegment?(segment)
            } catch {
                NSLog("[MapleReplay] segment \(seq) failed: \(error)")
            }
        }
    }

    /// Record a user id change in the spool manifest, for the row crash recovery posts.
    func updateUserId(_ userId: String) {
        workQueue.async { [spool] in spool?.updateUserId(userId) }
    }

    /// Delete the spool of a recorder that never started.
    func discardSpool() {
        workQueue.async { [spool] in spool?.remove() }
    }

    /// Wait for everything queued so far. Test seam.
    func drainQueue() {
        workQueue.sync {}
    }
}

/// Hands out a session's chunk sequence numbers.
///
/// Shared by every capture run of one session. A run retiring on the way to the
/// background can still be encoding its tail when the app comes back and the next run
/// starts, so neither can know where the other's numbers end; drawing from one counter
/// is what keeps two segments from claiming the same `x-maple-chunk-seq`.
final class ChunkSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var next: Int

    init(next: Int = 0) {
        self.next = max(0, next)
    }

    /// Reserve `count` consecutive numbers and return the first.
    func take(_ count: Int = 1) -> Int {
        lock.lock(); defer { lock.unlock() }
        let first = next
        next += max(0, count)
        return first
    }

    var peek: Int {
        lock.lock(); defer { lock.unlock() }
        return next
    }
}
