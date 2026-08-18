import Foundation
import MapleCore
import ObjectiveC

/// Traces outgoing `URLSession` requests and injects W3C `traceparent`.
///
/// The interception itself lives in `MapleURLProtocol`; this type holds the hooks it
/// needs and installs it. See that file for why a `URLProtocol` rather than swizzled
/// task-creation methods.
///
/// Set `TracingOptions.instrumentURLSession = .manual` and none of it is installed; the
/// host app calls `MapleTracing.trace(_:)` on requests it wants propagated.
public enum URLSessionInstrumentation {
    /// Everything the interceptor needs, published once at install.
    final class Hooks: @unchecked Sendable {
        let tracer: Tracer
        let shouldTrace: (URLRequest) -> Bool
        let shouldPropagate: (URLRequest) -> Bool
        init(
            tracer: Tracer,
            shouldTrace: @escaping (URLRequest) -> Bool,
            shouldPropagate: @escaping (URLRequest) -> Bool
        ) {
            self.tracer = tracer
            self.shouldTrace = shouldTrace
            self.shouldPropagate = shouldPropagate
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var hooks: Hooks?
    nonisolated(unsafe) private static var installed = false

    static var current: Hooks? {
        lock.lock(); defer { lock.unlock() }
        return hooks
    }

    /// Install the hooks, registering the interceptor once per process.
    ///
    /// Registration is never undone. Unregistering is only safe if nothing is in flight
    /// through the swapped implementations, which cannot be established from here — so
    /// `uninstall()` clears the hooks instead, and `canInit` then declines everything.
    static func install(hooks newHooks: Hooks) {
        lock.lock()
        hooks = newHooks
        let needsSwizzle = !installed
        installed = true
        lock.unlock()

        guard needsSwizzle else { return }
        installProtocol()
    }

    static func uninstall() {
        lock.lock()
        hooks = nil
        lock.unlock()
    }

    // MARK: - Span lifecycle, shared by the interceptor and by `.manual` mode

    /// Prepare a request for tracing: start the span, and inject `traceparent` when the
    /// target is allowed. Returns the request to actually send.
    static func begin(
        _ request: URLRequest,
        parent: SpanContext? = nil,
        hooks explicitHooks: Hooks? = nil
    ) -> (URLRequest, Span?) {
        guard let hooks = explicitHooks ?? current, hooks.shouldTrace(request) else { return (request, nil) }

        let method = request.httpMethod ?? "GET"
        var attributes: [String: AttributeValue] = [
            "http.request.method": .string(method),
        ]
        if let url = request.url {
            // `url.full` can carry credentials in the userinfo component; strip it rather
            // than shipping a password to the warehouse.
            attributes["url.full"] = .string(redact(url))
            if let host = url.host { attributes["server.address"] = .string(host) }
            if let port = url.port { attributes["server.port"] = .int(Int64(port)) }
        }

        // Client spans are named for the method alone — OTel's rule, and the reason the
        // operations list is not one row per URL.
        let span = hooks.tracer.startSpan(
            name: method,
            kind: .client,
            remoteParent: parent,
            attributes: attributes
        )

        var outgoing = request
        if hooks.shouldPropagate(request) {
            outgoing.setValue(span.context.traceParentHeader, forHTTPHeaderField: "traceparent")
            if let traceState = span.context.traceState, !traceState.isEmpty {
                outgoing.setValue(traceState, forHTTPHeaderField: "tracestate")
            }
        }
        return (outgoing, span)
    }

    /// Close a span from a response, and emit the matching `network` session event.
    static func finish(span: Span, response: URLResponse?, error: Error?, request: URLRequest) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status > 0 {
            span.setAttribute("http.response.status_code", .int(Int64(status)))
        }
        if let length = response?.expectedContentLength, length >= 0 {
            span.setAttribute("http.response.body.size", .int(length))
        }

        var failed = false
        if let error {
            span.setAttribute("error.type", .string("\(type(of: error))"))
            span.setStatus(.error("\(error)"))
            failed = true
        } else if status >= 500 {
            // 5xx only. A 4xx is the server correctly refusing something — an expired
            // token, a missing record — and marking those `Error` is what floods an error
            // dashboard with expected outcomes. The ingest gateway applies exactly this
            // rule to its own spans (`otel_status_for_rejection`), and the whole platform
            // is easier to read when both ends agree.
            span.setStatus(.error("HTTP \(status)"))
            failed = true
        } else if status > 0 {
            span.setStatus(.ok)
        }

        let now = Date()
        span.end(at: now)

        if failed { SessionSink.shared.recordError() }
        SessionSink.shared.emit(
            SessionEventDraft(
                kind: .network,
                timestamp: now,
                traceId: span.traceId,
                message: error.map { "\($0)" } ?? "",
                level: failed ? "error" : "",
                netMethod: request.httpMethod ?? "GET",
                netUrl: request.url.map(redact) ?? "",
                netStatus: status,
                netDurationMs: max(0, Int(now.timeIntervalSince(span.startTime) * 1000))
            )
        )
    }

    /// Attach a span to a task the host app created itself — `.manual` mode's other half.
    ///
    /// Uses KVO on `state` rather than a wrapped completion handler because a task handed
    /// to us may have neither.
    public static func observe(task: URLSessionTask, span: Span, request: URLRequest) {
        let observer = TaskCompletionObserver(span: span, request: request)
        objc_setAssociatedObject(task, &taskObserverKey, observer, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        observer.attach(to: task)
    }

    /// Strip userinfo (`https://user:pass@host/…`) before a URL is recorded anywhere.
    static func redact(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user != nil || components.password != nil else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        return components.string ?? url.absoluteString
    }

    // MARK: - Installation

    /// Two registrations, because `URLProtocol` reaches sessions by two different routes.
    ///
    /// `URLProtocol.registerClass` covers `URLSession.shared`, which most apps use. It
    /// does **not** cover a session the app built itself from a configuration — those
    /// consult only `configuration.protocolClasses`. So the two configuration factories
    /// are swizzled to include us, which is what makes `URLSession(configuration: .default)`
    /// traced as well.
    ///
    /// A session built from a configuration the app mutated *after* asking for `.default`
    /// keeps us, since the array is copied with our entry already in it. A session built
    /// from a hand-rolled configuration object is out of reach, and honestly so —
    /// `.manual` mode exists for that case.
    private static func installProtocol() {
        URLProtocol.registerClass(MapleURLProtocol.self)
        swizzleResume()
        swizzleConfigurationFactory(#selector(getter: URLSessionConfiguration.default),
                                    #selector(getter: URLSessionConfiguration.maple_default))
        swizzleConfigurationFactory(#selector(getter: URLSessionConfiguration.ephemeral),
                                    #selector(getter: URLSessionConfiguration.maple_ephemeral))
    }

    /// Captures the caller's active span onto the task, at the one moment we are still
    /// on the caller's thread.
    ///
    /// `URLProtocol` intercepts every `URLSession` API, which is why it is used at all —
    /// but it is invoked on the loading thread, where the caller's task-local context is
    /// gone. Without this the client span has no parent, so a request made inside a
    /// `checkout` span starts its own trace and the backend's server span hangs off a
    /// root that corresponds to nothing. Two requests in one flow came back with two
    /// unrelated trace ids, which is how this was found.
    ///
    /// `resume()` is the right hook: it is called on the caller's thread by *every* API
    /// including `async`, and it is a single selector rather than a list of task-creation
    /// methods that has to keep matching Apple's.
    private static func swizzleResume() {
        guard let originalMethod = class_getInstanceMethod(URLSessionTask.self, #selector(URLSessionTask.resume)),
              let replacementMethod = class_getInstanceMethod(URLSessionTask.self, #selector(URLSessionTask.maple_resume)) else {
            MapleLog.notice("MapleTracing", "could not capture span context on resume; client spans will be roots")
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }

    /// The span active when `resume()` was called on this task, if any.
    static func capturedParent(of task: URLSessionTask) -> SpanContext? {
        (objc_getAssociatedObject(task, &parentContextKey) as? ParentContextBox)?.context
    }

    private static func swizzleConfigurationFactory(_ original: Selector, _ replacement: Selector) {
        guard let cls = object_getClass(URLSessionConfiguration.self),
              let originalMethod = class_getClassMethod(URLSessionConfiguration.self, original),
              let replacementMethod = class_getClassMethod(URLSessionConfiguration.self, replacement) else {
            // Losing this is a coverage gap for app-created sessions, not a failure:
            // `URLSession.shared` is still covered by the registration above. A crash at
            // start-up would be an outage in the host app, which is strictly worse.
            MapleLog.notice("MapleTracing", "could not instrument \(original); sessions built from it are untraced")
            return
        }
        _ = cls
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

extension URLSessionConfiguration {
    /// After the exchange, this getter *is* the original.
    @objc class var maple_default: URLSessionConfiguration {
        let configuration = maple_default
        configuration.protocolClasses = [MapleURLProtocol.self] + (configuration.protocolClasses ?? [])
        return configuration
    }

    @objc class var maple_ephemeral: URLSessionConfiguration {
        let configuration = maple_ephemeral
        configuration.protocolClasses = [MapleURLProtocol.self] + (configuration.protocolClasses ?? [])
        return configuration
    }
}

nonisolated(unsafe) private var taskObserverKey: UInt8 = 0
nonisolated(unsafe) private var parentContextKey: UInt8 = 0

/// `objc_setAssociatedObject` needs a class; `SpanContext` is a struct.
final class ParentContextBox {
    let context: SpanContext
    init(_ context: SpanContext) { self.context = context }
}

extension URLSessionTask {
    /// After the exchange, this *is* `resume()`.
    @objc func maple_resume() {
        if objc_getAssociatedObject(self, &parentContextKey) == nil,
           let context = TraceContext.current?.context {
            objc_setAssociatedObject(self, &parentContextKey, ParentContextBox(context), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        maple_resume()
    }
}

/// Watches a task's `state` and closes the span when it completes.
///
/// Unused by the `URLProtocol` path, which knows exactly when a request finishes. Kept
/// for `.manual` mode, where a host app hands us a task it created itself.
final class TaskCompletionObserver: NSObject {
    private let span: Span
    private let request: URLRequest
    private var observation: NSKeyValueObservation?

    init(span: Span, request: URLRequest) {
        self.span = span
        self.request = request
    }

    func attach(to task: URLSessionTask) {
        observation = task.observe(\.state, options: [.new]) { [weak self] task, _ in
            guard let self, task.state == .completed else { return }
            self.observation?.invalidate()
            self.observation = nil
            URLSessionInstrumentation.finish(
                span: self.span,
                response: task.response,
                error: task.error,
                request: self.request
            )
        }
    }

    deinit {
        observation?.invalidate()
        // A task deallocated without ever completing (cancelled and released, or the
        // session invalidated) would otherwise leave the span open forever, and an
        // unended span is never exported at all.
        span.end()
    }
}
