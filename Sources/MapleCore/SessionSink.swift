import Foundation

/// The one piece of state replay and tracing both need.
///
/// Replay owns the session id; tracing owns the trace ids. Neither can see the other's
/// module — `MapleTracing` and `MapleReplay` are siblings, and making either depend on
/// the other would mean a host app that wants only tracing still links a screenshot
/// recorder. So the shared facts live here, in the target both of them already depend on.
///
/// This is the same role `packages/browser-session`'s sink plays on the web, and it
/// carries the same three links between a session and its traces:
///
///  1. `currentSessionId` — stamped onto every span as the `session.id` attribute.
///  2. `observedTraceIds(for:)` — drained onto the `ended` metadata row as `trace_ids`,
///     which is what `session_replays.TraceIds` is searched by when the UI resolves
///     "which recording produced this trace".
///  3. `activeTraceId` — the trace a distilled `session_events` row belongs to.
///
/// Everything is keyed by session id rather than held as a single mutable blob. iOS
/// rotates the session on every foreground transition, and a rotation that spilled the
/// previous session's trace ids onto the new row would attribute a recording to traces it
/// never produced.
public final class SessionSink: @unchecked Sendable {
    public static let shared = SessionSink()

    /// Ceiling on the trace ids remembered for one session.
    ///
    /// `trace_ids` is an unbounded `Array(String)` on the metadata row, and a long-lived
    /// session doing one request a second would put tens of thousands of 32-char ids in a
    /// single NDJSON line. The web SDK caps for the same reason. Oldest are dropped: the
    /// tail of a session is what someone is usually looking at.
    public static let maxTraceIdsPerSession = 512

    /// How many sessions' worth of state is kept.
    ///
    /// Two would do — the live session and the one being torn down — but teardown is
    /// asynchronous and crash recovery can post under a third id, so this is deliberately
    /// slack. It is bounded at all only because nothing else would ever evict it.
    private static let maxRetainedSessions = 4

    private struct SessionState {
        var traceIds: [String] = []
        var seenTraceIds: Set<String> = []
        var clickCount = 0
        var pageViews = 0
        var errorCount = 0
    }

    private let lock = NSLock()
    private var sessionId: String?
    private var states: [String: SessionState] = [:]
    private var order: [String] = []
    private var activeTraceIdProvider: (() -> String?)?

    /// Held in a box with its own lock because `SessionEvent.swift` extends this type
    /// from another file, and a Swift extension cannot add stored properties.
    final class EventRelayBox { var relay: ((SessionEventDraft) -> Void)? }
    let eventRelayBox = EventRelayBox()
    let eventRelayLock = NSLock()

    private init() {}

    // MARK: - Session identity

    /// The session spans should be stamped with, or `nil` when nothing is recording.
    public var currentSessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return sessionId
    }

    /// Called by the recorder when a session begins. Passing `nil` means the session
    /// ended and no new one has started — spans created after that carry no `session.id`,
    /// which is correct: they belong to no recording.
    public func publish(sessionId newId: String?) {
        lock.lock(); defer { lock.unlock() }
        sessionId = newId
        guard let newId else { return }
        // Survives the process, so a crash reported on the next launch can name the
        // session that produced it.
        LastSessionStore.remember(newId)
        if states[newId] == nil {
            states[newId] = SessionState()
            order.append(newId)
            evictLocked()
        }
    }

    // MARK: - Trace ids

    /// Record a trace id against the live session.
    ///
    /// Called on every span start, so it is on the hot path and does no allocation in the
    /// common (already-seen) case. A span created while nothing is recording is dropped
    /// here rather than parked — there is no session for it to belong to, and a later
    /// session must not inherit it.
    public func recordTraceId(_ traceId: String) {
        guard !traceId.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard let sessionId, var state = states[sessionId] else { return }
        guard state.seenTraceIds.insert(traceId).inserted else { return }
        state.traceIds.append(traceId)
        if state.traceIds.count > Self.maxTraceIdsPerSession {
            let dropped = state.traceIds.removeFirst()
            state.seenTraceIds.remove(dropped)
        }
        states[sessionId] = state
    }

    /// Trace ids observed during `sessionId`, oldest first.
    public func observedTraceIds(for sessionId: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return states[sessionId]?.traceIds ?? []
    }

    // MARK: - Counters
    //
    // These live here rather than on the recorder because the events that move them are
    // split across both modules: taps come from replay's touch tracker, screens and
    // failed requests from tracing. The metadata row reads them at session end.

    public func recordClick() { bump { $0.clickCount += 1 } }
    public func recordPageView() { bump { $0.pageViews += 1 } }
    public func recordError() { bump { $0.errorCount += 1 } }

    public struct Counters: Equatable, Sendable {
        public let clickCount: Int
        public let pageViews: Int
        public let errorCount: Int
    }

    public func counters(for sessionId: String) -> Counters {
        lock.lock(); defer { lock.unlock() }
        let state = states[sessionId] ?? SessionState()
        return Counters(
            clickCount: state.clickCount,
            pageViews: state.pageViews,
            errorCount: state.errorCount
        )
    }

    private func bump(_ mutate: (inout SessionState) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard let sessionId, var state = states[sessionId] else { return }
        mutate(&state)
        states[sessionId] = state
    }

    // MARK: - Active trace

    /// Installed by `MapleTracing` at start-up so `MapleReplay` can stamp a distilled
    /// event with the trace it happened inside, without depending on the tracer.
    ///
    /// Same shape as the browser SDK's `setActiveTraceIdProvider`, and for the same
    /// reason: the session package must work whether or not tracing is running.
    public func setActiveTraceIdProvider(_ provider: (() -> String?)?) {
        lock.lock(); defer { lock.unlock() }
        activeTraceIdProvider = provider
    }

    /// The trace currently in scope, if tracing is running and there is a span open.
    public var activeTraceId: String? {
        lock.lock()
        let provider = activeTraceIdProvider
        lock.unlock()
        // Deliberately outside the lock: the provider reads a task-local in the caller's
        // context, and holding a global lock across host-supplied code invites a deadlock.
        return provider?()
    }

    // MARK: - Lifecycle

    /// Forget everything about a session. Called after its `ended` row is built.
    public func discard(sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        states.removeValue(forKey: sessionId)
        order.removeAll { $0 == sessionId }
        if self.sessionId == sessionId { self.sessionId = nil }
    }

    /// Caller must hold `lock`.
    private func evictLocked() {
        while order.count > Self.maxRetainedSessions {
            let oldest = order.removeFirst()
            states.removeValue(forKey: oldest)
        }
    }

    /// Test seam. Process-global state is only testable if it can be returned to zero.
    public func resetForTesting() {
        lock.lock(); defer { lock.unlock() }
        sessionId = nil
        states.removeAll()
        order.removeAll()
        activeTraceIdProvider = nil
        eventRelayLock.lock()
        eventRelayBox.relay = nil
        eventRelayLock.unlock()
    }
}
