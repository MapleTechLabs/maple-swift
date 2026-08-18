import Foundation
import MapleCore
import UIKit

/// OpenTelemetry tracing for iOS, exporting to Maple's ingest gateway.
///
/// ```swift
/// var options = TracingOptions()
/// options.ingestKey = "maple_pk_…"
/// MapleTracing.shared.start(options: options)
/// ```
///
/// Started alongside session replay (see `Maple.start`), every span carries the live
/// `session.id` and every trace id is collected onto the session's `ended` metadata row —
/// so a trace resolves to the recording that produced it and back again. Started alone,
/// it is a plain tracer.
///
/// Outgoing `URLSession` requests are traced and carry W3C `traceparent`, so a span
/// created here is the *parent* of the server span your backend records. That is the
/// whole point: one trace, phone to database.
public final class MapleTracing: @unchecked Sendable {
    public static let shared = MapleTracing()

    private let lock = NSLock()
    private var options: TracingOptions?
    private var processor: BatchSpanProcessor?
    private var exporter: SpanExporter?
    private var tracerBox: Tracer?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// How long the background flush may hold a `UIApplication` background task. The OS
    /// terminates an app that overruns, so this stays well inside the budget iOS grants.
    private static let backgroundFlushTimeout: TimeInterval = 8

    private init() {}

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return tracerBox != nil
    }

    /// The tracer, or `nil` before `start()`. Prefer `MapleTracing.span(_:)`.
    public var tracer: Tracer? {
        lock.lock(); defer { lock.unlock() }
        return tracerBox
    }

    // MARK: - Lifecycle

    /// Begin tracing.
    ///
    /// Refuses without a well-formed ingest key, on the same reasoning `MapleReplay.start`
    /// uses: spans that can never be delivered cost the user battery and gain them
    /// nothing, and the 401 they would earn is invisible behind a best-effort exporter.
    public func start(options newOptions: TracingOptions, urlSession: URLSession? = nil) {
        lock.lock()
        guard tracerBox == nil else { lock.unlock(); return }
        lock.unlock()

        if let problem = IngestKey.validate(newOptions.ingestKey) {
            MapleLog.notice("MapleTracing", "not tracing — \(problem)")
            assertionFailure("[MapleTracing] \(problem)")
            return
        }
        let ingestKey = newOptions.ingestKey!.trimmingCharacters(in: .whitespacesAndNewlines)
        if ingestKey == IngestKey.sentinel {
            MapleLog.notice("MapleTracing", "using the gateway's sentinel key: spans will be accepted and discarded.")
        }

        let exporter = SpanExporter(options: newOptions, ingestKey: ingestKey, urlSession: urlSession)
        let processor = BatchSpanProcessor(
            exporter: exporter,
            maxQueued: newOptions.maxQueuedSpans,
            interval: newOptions.exportInterval
        )
        let tracer = Tracer(options: newOptions) { [weak processor] data in
            processor?.add(data)
        }

        lock.lock()
        self.options = newOptions
        self.exporter = exporter
        self.processor = processor
        self.tracerBox = tracer
        lock.unlock()

        processor.start()

        // Lets a `session_events` row know which trace it happened inside, without
        // `MapleReplay` depending on this module. Same seam as the browser SDK's
        // `setActiveTraceIdProvider`.
        SessionSink.shared.setActiveTraceIdProvider { TraceContext.activeTraceId }

        installLifecycleObservers()

        switch newOptions.instrumentURLSession {
        case .automatic:
            URLSessionInstrumentation.install(
                hooks: URLSessionInstrumentation.Hooks(
                    tracer: tracer,
                    shouldTrace: { [weak self] in self?.shouldTrace($0) ?? false },
                    shouldPropagate: { [weak self] in self?.shouldPropagate($0) ?? false }
                )
            )
        case .manual, .off:
            break
        }

        if newOptions.instrumentViewControllers {
            ViewControllerInstrumentation.install(tracer: tracer)
        }
    }

    /// Flush and stop. Idempotent.
    public func stop(completion: (() -> Void)? = nil) {
        lock.lock()
        let processor = self.processor
        self.tracerBox = nil
        self.processor = nil
        self.exporter = nil
        self.options = nil
        lock.unlock()

        URLSessionInstrumentation.uninstall()
        ViewControllerInstrumentation.uninstall()
        SessionSink.shared.setActiveTraceIdProvider(nil)
        removeLifecycleObservers()

        guard let processor else { completion?(); return }
        processor.forceFlush {
            processor.stop()
            processor.awaitPending(timeout: Self.backgroundFlushTimeout) {
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    /// Export everything queued now, and run `completion` once those requests finish.
    public func flush(completion: (() -> Void)? = nil) {
        lock.lock()
        let processor = self.processor
        lock.unlock()
        guard let processor else { completion?(); return }
        processor.forceFlush {
            processor.awaitPending(timeout: Self.backgroundFlushTimeout) {
                DispatchQueue.main.async { completion?() }
            }
        }
    }

    // MARK: - Public span API

    /// Start a span the caller ends itself.
    public func startSpan(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:]
    ) -> Span? {
        tracer?.startSpan(name: name, kind: kind, attributes: attributes)
    }

    /// Run `body` inside a span. A no-op wrapper when tracing is not running, so host code
    /// does not need a branch.
    @discardableResult
    public func span<T>(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:],
        _ body: (Span?) throws -> T
    ) rethrows -> T {
        guard let tracer else { return try body(nil) }
        return try tracer.withSpan(name, kind: kind, attributes: attributes) { try body($0) }
    }

    @discardableResult
    public func span<T>(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:],
        _ body: (Span?) async throws -> T
    ) async rethrows -> T {
        guard let tracer else { return try await body(nil) }
        return try await tracer.withSpan(name, kind: kind, attributes: attributes) { try await body($0) }
    }

    /// Record a screen appearance. For SwiftUI, where there is no view controller to
    /// swizzle — call it from `.onAppear` and end the returned span in `.onDisappear`.
    @discardableResult
    public func trackScreen(_ name: String) -> Span? {
        ViewControllerInstrumentation.screenAppeared(name)
    }

    // MARK: - Manual propagation
    //
    // The way in when `instrumentURLSession` is `.manual`, and the way to propagate
    // through a transport this SDK does not know about (a gRPC channel, a WebSocket
    // handshake, a third-party HTTP client).

    /// W3C headers for the active span, or empty when nothing is active.
    public func traceHeaders() -> [String: String] {
        guard let context = TraceContext.current?.context else { return [:] }
        var headers = ["traceparent": context.traceParentHeader]
        if let traceState = context.traceState, !traceState.isEmpty {
            headers["tracestate"] = traceState
        }
        return headers
    }

    /// Start a client span for `request` and return it with `traceparent` injected. The
    /// caller ends the span — `MapleTracing.shared.finish(span:response:error:request:)`.
    public func trace(_ request: URLRequest) -> (URLRequest, Span?) {
        guard let tracer else { return (request, nil) }
        // Reuse the automatic path's logic so manual and automatic modes cannot drift in
        // what they record or where they propagate.
        let hooks = URLSessionInstrumentation.Hooks(
            tracer: tracer,
            shouldTrace: { [weak self] in self?.shouldTrace($0) ?? false },
            shouldPropagate: { [weak self] in self?.shouldPropagate($0) ?? false }
        )
        return URLSessionInstrumentation.begin(request, hooks: hooks)
    }

    public func finish(span: Span, response: URLResponse?, error: Error?, request: URLRequest) {
        URLSessionInstrumentation.finish(span: span, response: response, error: error, request: request)
    }

    // MARK: - Targeting

    /// Is this a request we should trace at all?
    ///
    /// Two exclusions, both about the SDK's own traffic. Without them the exporter traces
    /// its own exports: one batch produces a span, that span produces a batch, and the
    /// loop never closes.
    ///
    /// The URL exclusion is scoped to the ingest **paths**, `{endpoint}/v1/…`, not to the
    /// endpoint's whole origin — matching the browser SDK's
    /// `ignoreUrls: [endpoint + "/v1/"]`. Excluding the origin looked equivalent and is
    /// not: a self-hosted deployment that puts its API and its ingest gateway behind one
    /// host would have had every request silently untraced, with no header and no span,
    /// which is indistinguishable from the SDK not working. The `x-maple-sdk` header is
    /// on every request this SDK makes, so loop prevention does not depend on the URL.
    func shouldTrace(_ request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        if request.value(forHTTPHeaderField: MapleSDK.hintHeader) != nil { return false }
        lock.lock()
        let endpoint = options?.endpoint
        lock.unlock()
        if let endpoint, url.absoluteString.hasPrefix(trimmed(endpoint) + "/v1/") { return false }
        return true
    }

    /// May this request carry `traceparent`?
    ///
    /// `nil` targets means everything the SDK traces — which is what makes "traces
    /// continue into your backend" true without configuration. Set
    /// `tracePropagationTargets` to keep trace ids off third-party services.
    func shouldPropagate(_ request: URLRequest) -> Bool {
        guard shouldTrace(request), let url = request.url else { return false }
        lock.lock()
        let targets = options?.tracePropagationTargets
        lock.unlock()
        guard let targets else { return true }
        let absolute = url.absoluteString
        return targets.contains { target in
            if absolute.range(of: target, options: .regularExpression) != nil { return true }
            return url.host == target
        }
    }

    private func trimmed(_ url: URL) -> String {
        var base = url.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    // MARK: - App lifecycle
    //
    // There is no `keepalive` and no unload event on iOS, so backgrounding is the last
    // moment anything can be sent — and the app can be suspended the instant the handler
    // returns. The flush therefore runs inside a background task, which is the only thing
    // that buys the request time to complete. The browser SDK does the same on
    // `visibilitychange`/`pagehide`; traces were the one signal that used to be lost there.

    private func installLifecycleObservers() {
        guard lifecycleObservers.isEmpty else { return }
        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushInBackgroundTask()
        }
        lifecycleObservers.append(observer)
    }

    private func removeLifecycleObservers() {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        lifecycleObservers.removeAll()
    }

    private func flushInBackgroundTask() {
        let application = UIApplication.shared
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = application.beginBackgroundTask(withName: "dev.maple.tracing.flush") {
            if identifier != .invalid {
                application.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
        flush {
            if identifier != .invalid {
                application.endBackgroundTask(identifier)
                identifier = .invalid
            }
        }
    }
}
