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
/// options.flushPolicy = .buffered(window: 30)
/// MapleReplay.shared.start(options: options, serviceName: "my-app")
/// // ... later, on an error:
/// MapleReplay.shared.flush(trigger: "error")
/// ```
///
/// Sessions end when the app goes to the background, and a new one begins when it comes
/// back. That is not a policy choice so much as the shape of the platform: there is no
/// `keepalive` and no unload event, so backgrounding is the last moment an `ended` row
/// can be sent at all, and a session that reported itself ended must not keep recording
/// under the same id.
public final class MapleReplay {
    public static let shared = MapleReplay()

    /// Everything `start()` was given, kept so a session can be re-established when the
    /// app returns to the foreground without the host app being involved.
    private struct Configuration {
        let options: ReplayOptions
        let ingestKey: String
        let serviceName: String
        let environment: String?
        let userId: String
    }

    private var configuration: Configuration?
    private var recorder: ReplayRecorder?
    private var metaRow: SessionMetaRow?
    private var sessionDirectory: URL?
    private(set) public var sessionId: String?

    /// Called on the main thread each time a segment is produced.
    ///
    /// Segments recovered from a previous session's crash arrive here too, shortly after
    /// `start()`. They carry a `replay.crash_recovery` breadcrumb and belong to the
    /// crashed session's id, not the current one.
    public var onSegment: ((SegmentArtifacts) -> Void)?

    private let recoveryQueue = DispatchQueue(label: "dev.maple.replay.recovery", qos: .utility)
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Guards the state `track(_:properties:)` touches, since a host app calls it from
    /// wherever its own code happens to be.
    private let eventLock = NSLock()
    private var transport: ReplayTransport?
    private var pendingEvents: [SessionEventRow] = []
    private var eventSeq = 0

    /// Distilled events are batched rather than sent one request per `track()`. Flushed
    /// on every segment boundary and at session end, so this only bounds a burst.
    private static let maxBufferedEvents = 64

    /// How long a background task will be held open waiting for the final flush. The OS
    /// terminates an app that overruns its background time, so this is deliberately well
    /// inside the budget iOS actually grants.
    private static let backgroundFlushTimeout: TimeInterval = 8

    private init() {}

    public var isRecording: Bool { recorder != nil }

    /// Directory the current session's segments are written to, when
    /// `ReplayOptions.writeSegmentsToDisk` is on.
    public var outputDirectory: URL? { recorder?.outputDirectory }

    /// Segments produced so far this session.
    public var segments: [SegmentArtifacts] { recorder?.artifacts ?? [] }

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
        guard recorder == nil else { return }

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

        configuration = Configuration(
            options: options,
            ingestKey: ingestKey,
            serviceName: serviceName,
            environment: environment,
            userId: userId
        )
        installLifecycleObservers()
        beginSession()

        // Once per launch, not once per session: a foreground/background cycle must not
        // re-scan for spools, and by then the only spool present is the live one.
        recoverPreviousSessions(options: options, activeSessionId: sessionId)
    }

    /// Stop recording, flush the tail, and close the session out.
    @MainActor
    public func stop() {
        configuration = nil
        removeLifecycleObservers()
        endSession(reason: "stop")
    }

    /// Emit whatever is currently buffered.
    ///
    /// In `.buffered` mode this is the only thing that produces a segment — wire it to
    /// your error handler. In `.continuous` mode it forces an early segment boundary.
    public func flush(trigger: String = "manual") {
        recorder?.flush(trigger: trigger)
    }

    /// Record a distilled `custom` session event — the mobile equivalent of the browser
    /// SDK's `track(name, props)`.
    ///
    /// Buffered and sent with the next segment rather than immediately: one request per
    /// call would be a lot of radio for a handful of bytes.
    public func track(_ name: String, properties: [String: String] = [:]) {
        enqueue(SessionEventDraft(kind: .custom, message: name, attributes: properties))
    }

    /// Buffer a distilled event, whoever raised it.
    ///
    /// `MapleTracing` raises `network` and `navigation` events through
    /// `SessionSink`'s relay; `track()` raises `custom` ones. They share one `Seq`
    /// counter because `Seq` is in the table's sorting key and two independent counters
    /// would interleave two event streams at the same ordinal.
    func enqueue(_ draft: SessionEventDraft) {
        eventLock.lock()
        guard let sessionId, let transport else { eventLock.unlock(); return }
        pendingEvents.append(SessionEventRow(sessionId: sessionId, seq: eventSeq, draft: draft))
        eventSeq += 1
        let batch = pendingEvents.count >= Self.maxBufferedEvents ? takePendingEventsLocked() : []
        eventLock.unlock()

        if !batch.isEmpty { transport.postEvents(batch) }
    }

    // MARK: - Sessions

    @MainActor
    private func beginSession() {
        guard let configuration, recorder == nil else { return }

        // The gateway rejects ids outside `[A-Za-z0-9_-]{1,128}`. A bare uuidString
        // qualifies; anything with braces or colons would 400 at upload time. It must
        // also be lowercase to survive the backend's public-id round trip — see
        // `SegmentWriter.newSessionId()`.
        let id = SegmentWriter.newSessionId()
        precondition(SegmentWriter.isSafeSessionId(id), "generated session id is not gateway-safe")
        sessionId = id

        let startedAt = Date()
        let transport = ReplayTransport(
            endpoint: configuration.options.endpoint,
            ingestKey: configuration.ingestKey,
            sessionId: id
        )

        eventLock.lock()
        self.transport = transport
        pendingEvents.removeAll()
        eventSeq = 0
        eventLock.unlock()

        // Publish before the recorder starts. Every span created from here on carries
        // this id as its `session.id` attribute, and every trace id it sees is collected
        // for the `ended` row — the two directions of the session/trace join.
        SessionSink.shared.publish(sessionId: id)
        SessionSink.shared.setEventRelay { [weak self] draft in
            self?.enqueue(draft)
        }

        let recorder = ReplayRecorder(
            sessionId: id,
            options: configuration.options,
            startedAt: startedAt,
            serviceName: configuration.serviceName,
            environment: configuration.environment,
            userId: configuration.userId
        )
        // Runs on the recorder's work queue. Upload starts here, from that queue —
        // there is no reason to bounce a finished chunk through the main thread first.
        recorder.onSegment = { [weak self] segment in
            transport.postBlob(segment)
            self?.flushPendingEvents(using: transport)
            DispatchQueue.main.async { self?.onSegment?(segment.artifacts) }
        }
        self.recorder = recorder
        sessionDirectory = recorder.outputDirectory

        let meta = SessionMetaRow(
            sessionId: id,
            startedAt: startedAt,
            status: .active,
            version: 1,
            serviceName: configuration.serviceName,
            environment: configuration.environment,
            userId: configuration.userId,
            recorded: true
        )
        metaRow = meta
        deliver(
            meta,
            using: transport,
            directory: configuration.options.writeSegmentsToDisk ? recorder.outputDirectory : nil
        )

        recorder.start()
    }

    /// Flush the tail, post the `ended` row, and tear the session down.
    ///
    /// `completion` runs once every request the teardown started has finished or timed
    /// out — which is what lets the background transition hold a background task open for
    /// exactly as long as it needs.
    @MainActor
    private func endSession(reason: String, completion: (() -> Void)? = nil) {
        guard let recorder, let transport else { completion?(); return }
        let meta = metaRow
        let directory = sessionDirectory
        let options = configuration?.options

        self.recorder = nil
        self.metaRow = nil
        self.sessionDirectory = nil
        self.sessionId = nil
        eventLock.lock()
        self.transport = nil
        let trailingEvents = takePendingEventsLocked()
        eventLock.unlock()
        SessionSink.shared.publish(sessionId: nil)
        SessionSink.shared.setEventRelay(nil)

        // `retiring` is captured by the completion closure, which the work queue holds
        // until it runs. Without that the recorder would deallocate the moment the
        // property above was cleared, and the final flush — the tail of the session,
        // usually the part someone actually wants — would never be emitted.
        let retiring = recorder
        retiring.flush(trigger: reason) { [weak self] in
            _ = retiring
            if !trailingEvents.isEmpty { transport.postEvents(trailingEvents) }
            if let meta {
                let counters = SessionSink.shared.counters(for: meta.sessionId)
                let ended = SessionMetaRow(
                    sessionId: meta.sessionId,
                    startedAt: meta.startedAt,
                    status: .ended,
                    version: 2,
                    serviceName: meta.serviceName,
                    environment: meta.environment,
                    userId: meta.userId,
                    recorded: true,
                    traceIds: SessionSink.shared.observedTraceIds(for: meta.sessionId),
                    clickCount: counters.clickCount,
                    pageViews: counters.pageViews,
                    errorCount: counters.errorCount
                )
                self?.deliver(
                    ended,
                    using: transport,
                    directory: options?.writeSegmentsToDisk == true ? directory : nil
                )
            }
            if let meta { SessionSink.shared.discard(sessionId: meta.sessionId) }
            transport.awaitPending(timeout: Self.backgroundFlushTimeout) {
                DispatchQueue.main.async { completion?() }
            }
        }
        retiring.stop()
    }

    /// Post a metadata row, and mirror it to `meta.ndjson` when disk output is on.
    ///
    /// The row is the **billed** unit and the only thing that makes a session appear in
    /// the UI — blobs are not metered. An SDK that uploads chunks and never posts one
    /// bills nothing and records into a void.
    private func deliver(_ meta: SessionMetaRow, using transport: ReplayTransport, directory: URL?) {
        let now = Date()
        transport.postMeta(meta, now: now)
        if let directory { meta.append(to: directory, now: now) }
    }

    // MARK: - Distilled events

    private func flushPendingEvents(using transport: ReplayTransport) {
        eventLock.lock()
        let batch = takePendingEventsLocked()
        eventLock.unlock()
        if !batch.isEmpty { transport.postEvents(batch) }
    }

    /// Caller must hold `eventLock`.
    private func takePendingEventsLocked() -> [SessionEventRow] {
        defer { pendingEvents.removeAll(keepingCapacity: true) }
        return pendingEvents
    }

    // MARK: - App lifecycle
    //
    // There is no `keepalive` and no unload beacon on iOS. Backgrounding is the last
    // point at which anything can be sent, and the app can be suspended the instant the
    // notification handlers return — so the final flush runs inside a `UIApplication`
    // background task, which is the only thing that buys the requests time to complete.

    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleDidEnterBackground() }
            }
        )
        lifecycleObservers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleWillEnterForeground() }
            }
        )
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    @MainActor
    private func handleDidEnterBackground() {
        guard recorder != nil else { return }

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

        endSession(reason: "background") {
            if identifier != .invalid {
                application.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
    }

    @MainActor
    private func handleWillEnterForeground() {
        // Only if `start()` is still in force and the background transition is what ended
        // the session. An explicit `stop()` clears the configuration, and stays stopped.
        guard configuration != nil, recorder == nil else { return }
        beginSession()
    }

    // MARK: - Crash recovery

    /// Encode, emit, and upload anything a previous session left spooled when it died.
    ///
    /// Deliberately after `recorder.start()`: recovery decodes and re-encodes up to a
    /// full window, and the current session's capture is the thing that must not wait.
    /// It also runs off the main thread — this is app launch, the worst possible place
    /// to spend hundreds of milliseconds.
    private func recoverPreviousSessions(options: ReplayOptions, activeSessionId: String?) {
        guard options.crashRecovery, let configuration else { return }
        let root = ReplayRecorder.rootDirectory(options: options)
        let limits = CrashRecovery.Limits(totalByteBudget: options.maxTotalSpoolBytes)
        let endpoint = options.endpoint
        let ingestKey = configuration.ingestKey
        let persistToDisk = options.writeSegmentsToDisk

        recoveryQueue.async { [weak self] in
            CrashRecovery.recoverPendingSessions(
                root: root,
                activeSessionId: activeSessionId,
                limits: limits,
                persistToDisk: persistToDisk
            ) { recovered in
                // A recovered session gets its own transport: the per-session kill
                // switches in `ReplayTransport` are per session id, and the crashed
                // session's budget has nothing to do with the live one's.
                let transport = ReplayTransport(
                    endpoint: endpoint,
                    ingestKey: ingestKey,
                    sessionId: recovered.sessionId
                )
                transport.postBlob(recovered.segment)
                // The crashed session posted its `active` row at its own start, so this
                // `ended` row is all that is missing. Its time is the last frame captured,
                // not the moment of recovery.
                transport.postMeta(recovered.endedRow, now: recovered.endedAt)
                DispatchQueue.main.async { self?.onSegment?(recovered.segment.artifacts) }

                // Recovery runs on a serial queue and this is the last use of the
                // transport, so hold the queue until its requests finish rather than
                // letting the transport fall out of scope mid-flight.
                let done = DispatchSemaphore(value: 0)
                transport.awaitPending(timeout: Self.backgroundFlushTimeout) { done.signal() }
                _ = done.wait(timeout: .now() + Self.backgroundFlushTimeout + 1)
            }
        }
    }
}
