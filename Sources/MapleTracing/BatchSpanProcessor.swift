import Foundation
import MapleCore

/// Buffers finished spans and exports them on a timer.
///
/// Bounded and drop-oldest. An app that has lost its network must not grow a span queue
/// until the OS kills it for memory, and when something has to go, the *newest* spans are
/// the ones worth keeping — they are the ones next to whatever the user is doing now.
final class BatchSpanProcessor: @unchecked Sendable {
    private let exporter: SpanExporter
    private let maxQueued: Int
    private let interval: TimeInterval

    private let queue = DispatchQueue(label: "dev.maple.tracing.batch", qos: .utility)
    private let lock = NSLock()
    private var buffer: [SpanData] = []
    private var droppedSinceLastWarning = 0
    private var timer: DispatchSourceTimer?

    init(exporter: SpanExporter, maxQueued: Int, interval: TimeInterval) {
        self.exporter = exporter
        self.maxQueued = max(1, maxQueued)
        self.interval = max(0.1, interval)
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
            timer.setEventHandler { [weak self] in self?.drainAndExport() }
            self.timer = timer
            timer.resume()
        }
    }

    /// Deliberately `async`, never `sync`.
    ///
    /// `stop()` is reached from `forceFlush`'s completion, which already runs on `queue`.
    /// A `sync` hop onto the queue you are already on is a deadlock, and dispatch traps
    /// rather than blocking — it surfaced as the test runner exiting mid-suite, not as a
    /// hang anyone could read. The timer is only ever touched from `queue`, so an async
    /// hop is just as safe.
    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    func add(_ span: SpanData) {
        lock.lock()
        buffer.append(span)
        if buffer.count > maxQueued {
            buffer.removeFirst(buffer.count - maxQueued)
            droppedSinceLastWarning += 1
        }
        let dropped = droppedSinceLastWarning
        if dropped > 0 { droppedSinceLastWarning = 0 }
        lock.unlock()

        if dropped > 0 {
            // Rate-limited by the shared logger, so a sustained overflow costs one line
            // per 30s rather than one per span.
            MapleLog.warnOnce("MapleTracing", "queue", "\(dropped) span(s) dropped; export is not keeping up")
        }
    }

    /// Export everything queued now. Used on the background transition, where the process
    /// may be suspended the instant the handler returns — the timer will not fire again.
    func forceFlush(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { completion?(); return }
            self.drainAndExport(completion: completion)
        }
    }

    func awaitPending(timeout: TimeInterval, completion: @escaping () -> Void) {
        exporter.awaitPending(timeout: timeout, completion: completion)
    }

    private func drainAndExport(completion: (() -> Void)? = nil) {
        lock.lock()
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()

        guard !batch.isEmpty else { completion?(); return }
        exporter.export(batch, completion: completion)
    }
}
