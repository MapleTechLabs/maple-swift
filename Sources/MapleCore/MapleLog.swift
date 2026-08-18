import Foundation

/// Rate-limited logging.
///
/// Every network path in this SDK is best-effort and must never throw into the host app,
/// but a wholly broken endpoint should not be *silent* either. One warning per 30s — the
/// same budget the browser SDK uses — makes a misconfiguration visible without flooding
/// the log of an app that is otherwise fine.
///
/// The budget is process-wide rather than per-subsystem on purpose: a bad endpoint breaks
/// replay upload and trace export at once, and two subsystems each warning every 30s is
/// twice the noise for one fact.
public enum MapleLog {
    private static let lock = NSLock()
    private static var lastWarnAt = Date.distantPast

    /// Log at most once per 30 seconds, whatever the caller.
    public static func warnOnce(_ subsystem: String, _ what: String, _ reason: Any) {
        lock.lock()
        let now = Date()
        let shouldWarn = now.timeIntervalSince(lastWarnAt) >= 30
        if shouldWarn { lastWarnAt = now }
        lock.unlock()

        guard shouldWarn else { return }
        NSLog("[\(subsystem)] \(what) POST failed (dropping, no retry): \(reason)")
    }

    /// Unconditional — for the handful of one-shot facts a developer must see
    /// (a refused key, a spent byte budget, a denied entitlement).
    public static func notice(_ subsystem: String, _ message: String) {
        NSLog("[\(subsystem)] \(message)")
    }

    /// Test seam: the rate limiter is process-global state, so a test that asserts on
    /// warning behaviour has to be able to clear it.
    public static func resetRateLimitForTesting() {
        lock.lock()
        lastWarnAt = .distantPast
        lock.unlock()
    }
}
