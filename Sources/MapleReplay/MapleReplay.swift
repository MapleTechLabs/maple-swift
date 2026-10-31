import Foundation
import MapleCore
import UIKit

/// Session replay for iOS.
///
/// Capture is masked screenshots encoded to H.264 and wrapped in rrweb-shaped events;
/// upload is three `POST`s against the Maple ingest gateway, best-effort and never
/// retried. See `ReplayTransport` for why not.
///
/// ```swift
/// var options = ReplayOptions()
/// options.ingestKey = "maple_pk_…"
/// options.sessionSampleRate = 0.1   // record 10% of sessions from the start
/// options.onErrorSampleRate = 1     // and keep the last 30 s of the rest for errors
/// MapleReplay.shared.start(options: options, serviceName: "my-app")
/// // ... later, on an error:
/// MapleReplay.shared.flush(trigger: "error")
/// ```
///
/// Backgrounding pauses the session: the tail is flushed and an `ended` row posted,
/// because there is no `keepalive` and no unload event, so it is the last moment anything
/// can be sent. Coming back within `backgroundSessionTimeout` resumes the same session
/// (with a fresh `active` row that supersedes the `ended` one); later than that starts a
/// new one.
///
/// Every public method is safe to call from any thread, except `start` and `stop`, which
/// are main-actor isolated.
public final class MapleReplay: @unchecked Sendable {
    public static let shared = MapleReplay()

    /// Everything `start()` was given, kept so a session can be re-established when the
    /// app returns to the foreground without the host app being involved.
    private struct Configuration {
        let options: ReplayOptions
        let ingestKey: String
        let serviceName: String
        let environment: String?
        var userId: String
    }

    /// One session, across however many capture runs its foreground stints take.
    private final class Session {
        let id: String
        let startedAt: Date
        var mode: ReplayMode
        let transport: ReplayTransport
        let sequencer = ChunkSequencer()
        /// Last metadata row version posted. The table keeps the highest, so every row
        /// takes the next one; the first is 1, which is the one ingest bills.
        var metaVersion = 0
        var run = 0
        var replayTrigger: String?
        var eventSeq = 0
        var pendingEvents: [SessionEventRow] = []
        /// Set while the app is in the background.
        var pausedAt: Date?

        init(id: String, startedAt: Date, mode: ReplayMode, transport: ReplayTransport) {
            self.id = id
            self.startedAt = startedAt
            self.mode = mode
            self.transport = transport
        }

        func nextVersion() -> Int {
            metaVersion += 1
            return metaVersion
        }
    }

    /// Guards every property below it. Taken briefly and never across a call out of this
    /// class, so a host callback can never deadlock against it.
    private let lock = NSLock()
    private var configuration: Configuration?
    private var session: Session?
    private var recorder: ReplayRecorder?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Called on the main thread each time a segment is produced.
    ///
    /// Segments recovered from a previous session's crash arrive here too, shortly after
    /// `start()`. They carry a `replay.crash_recovery` breadcrumb and belong to the
    /// crashed session's id, not the current one.
    public var onSegment: ((SegmentArtifacts) -> Void)? {
        get { locked { onSegmentHandler } }
        set { locked { onSegmentHandler = newValue } }
    }
    private var onSegmentHandler: ((SegmentArtifacts) -> Void)?

    private let recoveryQueue = DispatchQueue(label: "dev.maple.replay.recovery", qos: .utility)
    /// Crash recovery runs once per process. A `stop()` then `start()` would otherwise
    /// find the stopped run's spool mid-deletion and upload its tail a second time.
    private var didRecover = false

    /// Distilled events are batched rather than sent one request per `track()`. Flushed
    /// on every segment boundary and at session end, so this only bounds a burst.
    static let maxBufferedEvents = 64

    /// How long a background task will be held open waiting for the final flush. The OS
    /// terminates an app that overruns its background time, so this is deliberately well
    /// inside the budget iOS actually grants.
    static let backgroundFlushTimeout: TimeInterval = 8

    /// Test seam for the transport's `URLSession`. Production never sets it.
    var urlSessionOverride: URLSession?
    /// Test seam for the sampling roll.
    var randomSource: () -> Double = { Double.random(in: 0..<1) }
    /// Test seam: package tests have no `UIApplication` to hold a background task with.
    var holdsBackgroundTask = true

    init() {}

    /// The live session's id. `nil` before `start()`, after `stop()`, and while the app
    /// is in the background.
    public var sessionId: String? {
        locked { session?.pausedAt == nil ? session?.id : nil }
    }

    /// Whether frames are being captured right now. False for a session the sampling
    /// decided not to record, which still exists for spans and events.
    public var isRecording: Bool { locked { recorder != nil } }

    /// Directory the current session's segments are written to, when
    /// `ReplayOptions.writeSegmentsToDisk` is on.
    public var outputDirectory: URL? { locked { recorder?.outputDirectory } }

    /// Segments produced so far by the current capture run.
    public var segments: [SegmentArtifacts] { locked { recorder?.artifacts ?? [] } }

    /// What the live session records, for tests and diagnostics.
    var currentMode: ReplayMode? { locked { session?.mode } }

    // MARK: - Public lifecycle

    /// Begin recording and uploading.
    ///
    /// Refuses, loudly, without a well-formed ingest key: a capture that can never be
    /// delivered costs the user battery and gains them nothing, and the 401 it would
    /// earn is invisible behind a best-effort transport. In debug builds this trips an
    /// assertion; in release it logs and does not record.
    @MainActor
    public func start(
        options: ReplayOptions = ReplayOptions(),
        serviceName: String = "ios-app",
        environment: String? = nil,
        userId: String = ""
    ) {
        guard locked({ configuration == nil }) else { return }

        if let problem = ReplayTransport.validate(ingestKey: options.ingestKey) {
            NSLog("[MapleReplay] not recording — \(problem)")
            assertionFailure("[MapleReplay] \(problem)")
            return
        }
        let ingestKey = options.ingestKey!.trimmingCharacters(in: .whitespacesAndNewlines)
        if ingestKey.hasPrefix("maple_sk_") {
            NSLog("[MapleReplay] ingestKey is a private key. Ship the public maple_pk_ key instead — anything in an app binary is readable.")
        }
        if ingestKey == ReplayTransport.sentinelKey {
            NSLog("[MapleReplay] using the gateway's sentinel key: requests will be accepted and discarded, and no session will appear.")
        }

        let normalized = options.normalized()
        locked {
            configuration = Configuration(
                options: normalized,
                ingestKey: ingestKey,
                serviceName: serviceName,
                environment: environment,
                userId: userId
            )
        }
        installLifecycleObservers()
        beginSession()

        // Once per launch, not once per session: a foreground/background cycle must not
        // re-scan for spools, and by then the only spool present is the live one.
        recoverPreviousSessions(options: normalized, ingestKey: ingestKey)
    }

    /// Stop recording, flush the tail, and close the session out.
    @MainActor
    public func stop() {
        removeLifecycleObservers()
        let retired: Session? = locked {
            configuration = nil
            return session
        }
        guard let retired else { return }
        pauseSession(reason: "stop") { [weak self] in
            self?.discard(retired)
        }
    }

    /// Emit whatever is currently buffered.
    ///
    /// In an error-buffered session this uploads the last `errorBufferWindow` seconds
    /// and records continuously from then on: wire it to your error handler. In a
    /// recorded session it forces an early segment boundary.
    public func flush(trigger: String = "manual") {
        let action: (recorder: ReplayRecorder, promote: Bool, segment: TimeInterval)? = locked {
            guard let session, session.pausedAt == nil, let recorder, let configuration else { return nil }
            let promote = session.mode == .buffer
            if promote {
                session.mode = .record
                session.replayTrigger = "error"
            }
            return (recorder, promote, configuration.options.segmentDuration)
        }
        guard let action else { return }
        if action.promote {
            // The row first: the session must read as recorded before its first chunk
            // lands, or the UI briefly labels a playable session "Not recorded".
            postMeta(status: .active)
            action.recorder.promote(to: action.segment, trigger: trigger)
        } else {
            action.recorder.flush(trigger: trigger)
        }
    }

    /// Record a distilled `custom` session event: the mobile equivalent of the browser
    /// SDK's `track(name, props)`.
    ///
    /// Buffered and sent with the next segment rather than immediately: one request per
    /// call would be a lot of radio for a handful of bytes.
    public func track(_ name: String, properties: [String: String] = [:]) {
        enqueue(SessionEventDraft(kind: .custom, message: name, attributes: properties))
    }

    /// Attach a user id to the session, typically right after sign-in.
    ///
    /// Posts a fresh `active` row so the id is searchable while the session is still
    /// live, and carries over to later sessions until changed. Pass `""` on sign-out.
    public func setUserId(_ userId: String) {
        let changed: Bool = locked {
            guard configuration != nil, configuration?.userId != userId else { return false }
            configuration?.userId = userId
            return session?.pausedAt == nil && session != nil
        }
        if changed { postMeta(status: .active) }
    }

    /// Buffer a distilled event, whoever raised it.
    ///
    /// `MapleTracing` raises `network` and `navigation` events through `SessionSink`'s
    /// relay; `track()` raises `custom` ones. They share one `Seq` counter because `Seq`
    /// is in the table's sorting key and two independent counters would interleave two
    /// event streams at the same ordinal.
    func enqueue(_ draft: SessionEventDraft) {
        let send: (ReplayTransport, [SessionEventRow])? = locked {
            guard let session, session.pausedAt == nil else { return nil }
            session.pendingEvents.append(SessionEventRow(sessionId: session.id, seq: session.eventSeq, draft: draft))
            session.eventSeq += 1
            guard session.pendingEvents.count >= Self.maxBufferedEvents else { return nil }
            return (session.transport, takeEvents(session))
        }
        if let send { send.0.postEvents(send.1) }
    }

    // MARK: - Sessions

    @MainActor
    private func beginSession() {
        let created: Session? = locked {
            guard let configuration, session == nil else { return nil }
            // The gateway rejects ids outside `[A-Za-z0-9_-]{1,128}`, and the id must be
            // lowercase to survive the backend's public-id round trip. See
            // `SegmentWriter.newSessionId()`.
            let id = SegmentWriter.newSessionId()
            precondition(SegmentWriter.isSafeSessionId(id), "generated session id is not gateway-safe")
            let transport = ReplayTransport(
                endpoint: configuration.options.endpoint,
                ingestKey: configuration.ingestKey,
                sessionId: id,
                urlSession: urlSessionOverride
            )
            let created = Session(
                id: id,
                startedAt: Date(),
                mode: ReplayMode.roll(configuration.options, random: randomSource),
                transport: transport
            )
            session = created
            return created
        }
        guard let created else { return }
        activate(created)
    }

    /// Publish a session, announce it, and start capturing if it is sampled. Shared by a
    /// new session and one resumed from the background.
    @MainActor
    private func activate(_ session: Session) {
        // Publish before the recorder starts. Every span created from here on carries
        // this id as its `session.id` attribute, and every trace id it sees is collected
        // for the `ended` row: the two directions of the session/trace join.
        SessionSink.shared.publish(sessionId: session.id)
        SessionSink.shared.setEventRelay { [weak self] draft in
            self?.enqueue(draft)
        }
        postMeta(status: .active)
        startCaptureRun(for: session)
    }

    @MainActor
    private func startCaptureRun(for session: Session) {
        let recorder: ReplayRecorder? = locked {
            guard let configuration, session.mode != .off, self.session === session, self.recorder == nil else {
                return nil
            }
            let options = configuration.options
            let recorder = ReplayRecorder(
                sessionId: session.id,
                options: options,
                capture: session.mode == .buffer
                    ? .buffered(window: options.errorBufferWindow)
                    : .continuous(segmentDuration: options.segmentDuration),
                sequencer: session.sequencer,
                run: session.run,
                mode: session.mode,
                startedAt: session.startedAt,
                serviceName: configuration.serviceName,
                environment: configuration.environment,
                userId: configuration.userId
            )
            let transport = session.transport
            // Runs on the recorder's work queue. Upload starts here, from that queue:
            // there is no reason to bounce a finished chunk through the main thread first.
            recorder.onSegment = { [weak self] segment in
                transport.postBlob(segment)
                self?.flushEvents(of: session)
                DispatchQueue.main.async { self?.onSegment?(segment.artifacts) }
            }
            self.recorder = recorder
            return recorder
        }
        recorder?.start()
    }

    /// Flush the tail, post the `ended` row, and stop capturing. The session itself is
    /// kept so the app coming back can resume it.
    ///
    /// `completion` runs on the main thread once every request the teardown started has
    /// finished or timed out, which is what lets the background transition hold a
    /// background task open for exactly as long as it needs.
    @MainActor
    private func pauseSession(reason: String, completion: (() -> Void)? = nil) {
        let state: (Session, ReplayRecorder?, [SessionEventRow])? = locked {
            guard let session, session.pausedAt == nil else { return nil }
            session.pausedAt = Date()
            let retiring = recorder
            recorder = nil
            return (session, retiring, takeEvents(session))
        }
        guard let (session, retiring, trailingEvents) = state else { completion?(); return }

        SessionSink.shared.publish(sessionId: nil)
        SessionSink.shared.setEventRelay(nil)
        let transport = session.transport

        let finish: () -> Void = { [weak self] in
            if !trailingEvents.isEmpty { transport.postEvents(trailingEvents) }
            self?.postMeta(status: .ended, for: session)
            transport.awaitPending(timeout: Self.backgroundFlushTimeout) {
                DispatchQueue.main.async { completion?() }
            }
        }

        guard let retiring else { finish(); return }
        // An error-buffered session uploads only for an error, and leaving the app is
        // not one: its window is dropped with the run.
        if session.mode == .buffer {
            retiring.stop()
            finish()
            return
        }
        // `retiring` is captured by the completion closure, which the work queue holds
        // until it runs. Without that the recorder would deallocate the moment the
        // property above was cleared, and the final flush (the tail of the session,
        // usually the part someone actually wants) would never be emitted.
        retiring.flush(trigger: reason) {
            _ = retiring
            finish()
        }
        retiring.stop()
    }

    /// Bring a paused session back, or replace it if it was away too long.
    @MainActor
    private func resumeOrRotate() {
        let decision: (resume: Session?, expired: Session?) = locked {
            guard let configuration, let session, let pausedAt = session.pausedAt else { return (nil, nil) }
            let away = Date().timeIntervalSince(pausedAt)
            if away >= 0, away < configuration.options.backgroundSessionTimeout {
                session.pausedAt = nil
                session.run += 1
                return (session, nil)
            }
            self.session = nil
            return (nil, session)
        }
        if let resumed = decision.resume {
            activate(resumed)
        } else {
            if let expired = decision.expired { SessionSink.shared.discard(sessionId: expired.id) }
            beginSession()
        }
    }

    private func discard(_ retired: Session) {
        locked {
            if session === retired { session = nil }
        }
        SessionSink.shared.discard(sessionId: retired.id)
    }

    // MARK: - Metadata

    /// Post a metadata row for the live session, or for `target` when it is given.
    ///
    /// The row is the **billed** unit and the only thing that makes a session appear in
    /// the UI; blobs are not metered. An SDK that uploads chunks and never posts one
    /// bills nothing and records into a void.
    private func postMeta(status: SessionMetaRow.Status, for target: Session? = nil) {
        let built: (SessionMetaRow, ReplayTransport, URL?)? = locked {
            guard let session = target ?? session, let configuration else {
                // After `stop()` the configuration is gone but the closing row is still
                // owed, so fall back to what the row was last built from.
                guard let target, let last = lastConfiguration else { return nil }
                return build(status: status, session: target, configuration: last)
            }
            lastConfiguration = configuration
            return build(status: status, session: session, configuration: configuration)
        }
        guard let (row, transport, directory) = built else { return }
        let now = Date()
        transport.postMeta(row, now: now)
        if let directory { row.append(to: directory, now: now) }
    }

    /// Caller holds `lock`.
    private func build(
        status: SessionMetaRow.Status,
        session: Session,
        configuration: Configuration
    ) -> (SessionMetaRow, ReplayTransport, URL?) {
        let counters = SessionSink.shared.counters(for: session.id)
        let row = SessionMetaRow(
            sessionId: session.id,
            startedAt: session.startedAt,
            status: status,
            version: session.nextVersion(),
            serviceName: configuration.serviceName,
            environment: configuration.environment,
            userId: configuration.userId,
            recorded: session.mode == .record,
            traceIds: status == .ended ? SessionSink.shared.observedTraceIds(for: session.id) : [],
            clickCount: counters.clickCount,
            pageViews: counters.pageViews,
            errorCount: counters.errorCount,
            replayTrigger: session.replayTrigger
        )
        let directory = configuration.options.writeSegmentsToDisk
            ? ReplayRecorder.rootDirectory(options: configuration.options)
                .appendingPathComponent(session.id, isDirectory: true)
            : nil
        return (row, session.transport, directory)
    }

    private var lastConfiguration: Configuration?

    // MARK: - Distilled events

    private func flushEvents(of session: Session) {
        let batch = locked { takeEvents(session) }
        if !batch.isEmpty { session.transport.postEvents(batch) }
    }

    /// Caller holds `lock`.
    private func takeEvents(_ session: Session) -> [SessionEventRow] {
        defer { session.pendingEvents.removeAll(keepingCapacity: true) }
        return session.pendingEvents
    }

    // MARK: - App lifecycle
    //
    // There is no `keepalive` and no unload beacon on iOS. Backgrounding is the last
    // point at which anything can be sent, and the app can be suspended the instant the
    // notification handlers return, so the final flush runs inside a `UIApplication`
    // background task, which is the only thing that buys the requests time to complete.

    @MainActor
    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleDidEnterBackground() }
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleWillEnterForeground() }
            }
        )
    }

    @MainActor
    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    /// Internal so tests can drive the lifecycle without a real app transition.
    @MainActor
    func handleDidEnterBackground() {
        guard locked({ session != nil && session?.pausedAt == nil }) else { return }
        guard holdsBackgroundTask else {
            pauseSession(reason: "background")
            return
        }

        let application = UIApplication.shared
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = application.beginBackgroundTask(withName: "dev.maple.replay.flush") {
            // Expiration handler: the OS is out of patience. Ending the task here is what
            // keeps the app from being killed outright; the in-flight requests are
            // abandoned, which is the same outcome the no-retry policy already accepts.
            if identifier != .invalid {
                application.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }

        pauseSession(reason: "background") {
            if identifier != .invalid {
                application.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
    }

    @MainActor
    func handleWillEnterForeground() {
        // Only if `start()` is still in force. An explicit `stop()` clears the
        // configuration, and stays stopped.
        guard locked({ configuration != nil }) else { return }
        if locked({ session == nil }) {
            beginSession()
        } else {
            resumeOrRotate()
        }
    }

    // MARK: - Crash recovery

    /// Encode, emit, and upload anything a previous session left spooled when it died.
    ///
    /// Deliberately after the live session started: recovery decodes and re-encodes up to
    /// a full window, and the current session's capture is the thing that must not wait.
    /// It also runs off the main thread, because this is app launch.
    private func recoverPreviousSessions(options: ReplayOptions, ingestKey: String) {
        let activeSessionId: String? = locked {
            guard options.crashRecovery, !didRecover else { return nil }
            didRecover = true
            return session?.id ?? ""
        }
        guard let activeSessionId else { return }
        let root = ReplayRecorder.rootDirectory(options: options)
        let limits = CrashRecovery.Limits(totalByteBudget: options.maxTotalSpoolBytes)
        let endpoint = options.endpoint
        let persistToDisk = options.writeSegmentsToDisk
        let urlSession = urlSessionOverride

        recoveryQueue.async { [weak self] in
            CrashRecovery.recoverPendingSessions(
                root: root,
                activeSessionId: activeSessionId.isEmpty ? nil : activeSessionId,
                limits: limits,
                persistToDisk: persistToDisk
            ) { recovered in
                // A recovered session gets its own transport: the per-session kill
                // switches in `ReplayTransport` are per session id, and the crashed
                // session's budget has nothing to do with the live one's.
                let transport = ReplayTransport(
                    endpoint: endpoint,
                    ingestKey: ingestKey,
                    sessionId: recovered.sessionId,
                    urlSession: urlSession
                )
                for segment in recovered.segments {
                    transport.postBlob(segment)
                    DispatchQueue.main.async { self?.onSegment?(segment.artifacts) }
                }
                // Its time is the last frame captured, not the moment of recovery.
                transport.postMeta(recovered.endedRow, now: recovered.endedAt)

                // Recovery runs on a serial queue and this is the last use of the
                // transport, so hold the queue until its requests finish rather than
                // letting the transport fall out of scope mid-flight.
                let done = DispatchSemaphore(value: 0)
                transport.awaitPending(timeout: Self.backgroundFlushTimeout) { done.signal() }
                _ = done.wait(timeout: .now() + Self.backgroundFlushTimeout + 1)
            }
        }
    }

    /// Wait for crash recovery to finish. Test seam.
    func drainRecovery() {
        recoveryQueue.sync {}
    }

    /// Return to the never-started state. Test seam: the singleton is process-global.
    @MainActor
    func resetForTesting() {
        removeLifecycleObservers()
        let retiring = locked { () -> ReplayRecorder? in
            let retiring = recorder
            configuration = nil
            lastConfiguration = nil
            session = nil
            recorder = nil
            onSegmentHandler = nil
            didRecover = false
            urlSessionOverride = nil
            holdsBackgroundTask = true
            randomSource = { Double.random(in: 0..<1) }
            return retiring
        }
        retiring?.stop()
        SessionSink.shared.publish(sessionId: nil)
        SessionSink.shared.setEventRelay(nil)
    }

    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }
}
