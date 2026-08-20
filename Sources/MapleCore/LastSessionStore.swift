import Foundation

/// Remembers the session id across a process boundary.
///
/// A crash is reported on the *next* launch, so the run that produced it is already gone
/// by the time anything can describe it — including its session id, which is the only
/// thing tying the crash to the recording of the seconds before it. One small file,
/// rewritten whenever the session rotates, is what survives an uncatchable signal.
///
/// It lives here rather than in either product for the usual reason: `MapleTracing`
/// reports the crash, `MapleReplay` owns the session id, and neither can see the other.
public enum LastSessionStore {
    private static let lock = NSLock()
    private static var loaded = false
    private static var previous: String?
    private static var url: URL?

    /// Point the store at a directory and capture what the previous run left there.
    ///
    /// Explicitly separate from `previousSessionId` so the read happens once, early, at
    /// `start()`: the live session overwrites the file within moments, and a crash
    /// payload arriving later in the launch would otherwise read the *current* session
    /// and claim the crash belongs to a recording made after it.
    public static func configure(directory: URL) {
        lock.lock(); defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        let file = directory.appendingPathComponent("last-session")
        url = file
        let value = try? String(contentsOf: file, encoding: .utf8)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        previous = (trimmed?.isEmpty == false) ? trimmed : nil
    }

    /// The session id the previous run ended on, or `nil` if there was none.
    public static var previousSessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return previous
    }

    /// Persist the live session id. Cheap and rare — sessions rotate on foreground
    /// transitions, not on every span, so this is not on the hot path.
    ///
    /// A no-op until `configure` has run, which is deliberate: with crash reporting off
    /// there is nothing to correlate and no reason to touch the disk at all.
    public static func remember(_ sessionId: String?) {
        lock.lock()
        let file = url
        lock.unlock()
        guard let file, let sessionId, !sessionId.isEmpty else { return }
        try? sessionId.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Test seam. The store is process-global because the thing it models is.
    static func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        loaded = false
        previous = nil
        url = nil
    }
}
