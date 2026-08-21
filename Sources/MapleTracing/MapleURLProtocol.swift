import Foundation
import MapleCore

/// Intercepts outgoing requests below every `URLSession` API.
///
/// The obvious approach — swizzling `URLSession`'s task-creation methods — works for the
/// completion-handler and delegate APIs and **silently does not fire for `async`
/// `data(for:)`**, which on current iOS is implemented without going through any of those
/// Objective-C selectors. That failure is invisible: spans are still produced by anything
/// else, so the SDK looks healthy while the one API most modern apps call ships no
/// `traceparent` at all. It was caught here only by asserting on bytes that left the
/// process, not on what the tracer built.
///
/// `URLProtocol` sits underneath all of them, so there is one interception point and no
/// list of selectors to keep matching Apple's.
///
/// Recursion is prevented with `URLProtocol.setProperty` rather than a marker header:
/// the property is invisible on the wire, so nothing leaks to the customer's backend.
final class MapleURLProtocol: URLProtocol {
    private static let handledKey = "dev.maple.tracing.handled"

    /// Largest body the relay will hold in memory to reproduce a fixed-length request.
    /// Past this it hands the original stream on instead, so tracing never doubles the
    /// residency of a large upload.
    private static let maxBufferedBodyBytes = 1 << 20

    /// Test seam. A `URLSession` built from a configuration does not consult
    /// globally-registered protocols, so a test's stub protocol is invisible to the relay
    /// and every assertion about what we actually send would be untestable without this.
    nonisolated(unsafe) static var relayProtocolClassesForTesting: [AnyClass] = [] {
        didSet { relayLock.lock(); cachedRelay = nil; relayLock.unlock() }
    }

    private static let relayLock = NSLock()
    nonisolated(unsafe) private static var cachedRelay: URLSession?

    /// Performs the real request. Built from a configuration rather than `URLSession.shared`,
    /// so it never consults the global registration and can never re-enter us — the
    /// `handled` property is the second line of defence, not the first.
    private static var relay: URLSession {
        relayLock.lock(); defer { relayLock.unlock() }
        if let cachedRelay { return cachedRelay }
        let configuration = URLSessionConfiguration.default
        let inherited = (configuration.protocolClasses ?? []).filter { $0 != MapleURLProtocol.self }
        configuration.protocolClasses = relayProtocolClassesForTesting + inherited
        let session = URLSession(configuration: configuration, delegate: RelayDelegate.shared, delegateQueue: nil)
        cachedRelay = session
        return session
    }

    private var relayTask: URLSessionTask?
    private var span: Span?
    /// Arrives in `didFinishCollecting`, which `URLSession` delivers before
    /// `didCompleteWithError` — so it is always here in time to be written onto the span
    /// `relayFinished` is about to close.
    private var metrics: TransactionMetrics?

    override class func canInit(with request: URLRequest) -> Bool {
        guard property(forKey: handledKey, in: request) == nil else { return false }
        guard let hooks = URLSessionInstrumentation.current else { return false }
        // Bodies used to be declined here, on the theory that a stream cannot be replayed.
        // Foundation hands a protocol *every* body as `httpBodyStream` — `httpBody`,
        // `from: Data`, `fromFile:` and a delegate-fed stream alike, measured per API in
        // `URLProtocolBodyVisibilityTests` — so that guard did not skip streams, it skipped
        // every POST, PUT and PATCH an app makes: no span, and no `traceparent`, which left
        // the backend's server span in a trace of its own. `startLoading` carries the body
        // across instead, by value or by reference.
        return hooks.shouldTrace(request)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // The parent was captured on the caller's thread at `resume()`; by the time we
        // get here the task-local context belongs to whatever thread URLSession chose.
        let parent = task.flatMap(URLSessionInstrumentation.capturedParent(of:))
        let (traced, span) = URLSessionInstrumentation.begin(request, parent: parent)
        self.span = span

        let outgoing = (traced as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        Self.setProperty(true, forKey: Self.handledKey, in: outgoing)

        // How the body travels decides how the request is framed on the wire, so the rule
        // is to preserve whatever framing the app's own request would have had: a declared
        // length is reproduced by value, an undeclared one is handed on as a stream and
        // stays chunked. Buffering the undeclared case instead would turn a chunked upload
        // of unknown size into a resident allocation of unknown size.
        var passthrough: InputStream?
        if let stream = request.httpBodyStream {
            if let length = Self.declaredBodyLength(of: request), length <= Self.maxBufferedBodyBytes {
                guard let body = Self.read(stream, exactly: length) else {
                    // The stream is spent and came up short, so there is no correct request
                    // left to send. Failing is the only honest outcome — a truncated upload
                    // would be a silent data loss caused by tracing.
                    span?.setStatus(.error("request body could not be read"))
                    fail(with: URLError(.cannotLoadFromNetwork))
                    return
                }
                // Assigning the body is what clears the stream: the two are mutually
                // exclusive on `NSMutableURLRequest`, and setting the stream to nil
                // afterwards clears the body right back out again.
                outgoing.httpBody = body
                span?.setAttribute("http.request.body.size", .int(Int64(body.count)))
            } else {
                passthrough = stream
            }
        }

        let task: URLSessionTask
        if let passthrough {
            // `uploadTask(withStreamedRequest:)` ignores the request's own stream and asks
            // the delegate for one — the same contract the app was already using, since an
            // undeclared length is what a streamed upload looks like from below.
            task = Self.relay.uploadTask(withStreamedRequest: outgoing as URLRequest)
            RelayDelegate.shared.register(task: task, protocolInstance: self, bodyStream: passthrough)
        } else {
            task = Self.relay.dataTask(with: outgoing as URLRequest)
            RelayDelegate.shared.register(task: task, protocolInstance: self)
        }
        self.relayTask = task
        task.resume()
    }

    /// `Content-Length` as the app set it, or as Foundation derived it from a `Data` or
    /// file body. Absent for a delegate-fed stream, which is exactly the case that must not
    /// be buffered.
    private static func declaredBodyLength(of request: URLRequest) -> Int? {
        guard let value = request.value(forHTTPHeaderField: "Content-Length"),
              let length = Int(value), length >= 0
        else { return nil }
        return length
    }

    /// Reads exactly `length` bytes, or returns nil. A short read is a failure rather than
    /// a smaller body: the request declared a length and the relay has to honour it.
    private static func read(_ stream: InputStream, exactly length: Int) -> Data? {
        stream.open()
        defer { stream.close() }
        var data = Data(capacity: length)
        var buffer = [UInt8](repeating: 0, count: min(length, 64 * 1024))
        while data.count < length {
            let read = stream.read(&buffer, maxLength: min(buffer.count, length - data.count))
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data.count == length ? data : nil
    }

    private func fail(with error: Error) {
        span.map { URLSessionInstrumentation.finish(span: $0, response: nil, error: error, request: request) }
        span = nil
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {
        if let relayTask {
            relayTask.cancel()
            RelayDelegate.shared.unregister(task: relayTask)
        }
        // A cancelled request still has to close its span, or it is never exported and
        // the trace keeps a hole where the request was.
        span?.end()
        span = nil
        relayTask = nil
    }

    // MARK: - Relay callbacks

    fileprivate func relayReceived(response: URLResponse) {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }

    fileprivate func relayReceived(data: Data) {
        client?.urlProtocol(self, didLoad: data)
    }

    fileprivate func relayCollected(_ metrics: URLSessionTaskMetrics) {
        self.metrics = TransactionMetrics(metrics)
    }

    fileprivate func relayFinished(response: URLResponse?, error: Error?) {
        if let span {
            // Before `finish`, which ends the span: an attribute set after `end` is lost.
            metrics?.apply(to: span)
            metrics = nil
            URLSessionInstrumentation.finish(span: span, response: response, error: error, request: request)
            self.span = nil
        }
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
        relayTask = nil
    }
}

/// Streams the relayed response back rather than buffering it.
///
/// The completion-handler form would be a third of this code and would hold an entire
/// download in memory — a protocol that quietly turns every streamed response into a
/// resident allocation is not a reasonable thing to install in someone's app.
private final class RelayDelegate: NSObject, URLSessionDataDelegate {
    nonisolated(unsafe) static let shared = RelayDelegate()

    private let lock = NSLock()
    private var handlers: [Int: MapleURLProtocol] = [:]
    private var bodyStreams: [Int: InputStream] = [:]

    func register(task: URLSessionTask, protocolInstance: MapleURLProtocol, bodyStream: InputStream? = nil) {
        lock.lock(); defer { lock.unlock() }
        handlers[task.taskIdentifier] = protocolInstance
        bodyStreams[task.taskIdentifier] = bodyStream
    }

    func unregister(task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: task.taskIdentifier)
        bodyStreams.removeValue(forKey: task.taskIdentifier)
    }

    /// Hands over the app's own body stream, once.
    ///
    /// A second ask means a retry or a redirect, and the stream is spent by then — the same
    /// position the app itself would be in, since it handed the stream downwards rather than
    /// a way to make another one. `nil` fails that attempt instead of resending a partial
    /// body.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        lock.lock()
        let stream = bodyStreams.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        completionHandler(stream)
    }

    private func handler(for task: URLSessionTask) -> MapleURLProtocol? {
        lock.lock(); defer { lock.unlock() }
        return handlers[task.taskIdentifier]
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        handler(for: dataTask)?.relayReceived(response: response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        handler(for: dataTask)?.relayReceived(data: data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        handler(for: task)?.relayCollected(metrics)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let handler = handler(for: task)
        unregister(task: task)
        handler?.relayFinished(response: task.response, error: error)
    }
}
