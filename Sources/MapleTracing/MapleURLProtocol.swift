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
        // Body streams cannot be replayed, and re-issuing the request is exactly what
        // this protocol does. Leaving them alone loses a span; consuming them would lose
        // the upload.
        guard request.httpBodyStream == nil else { return false }
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

        let task = Self.relay.dataTask(with: outgoing as URLRequest)
        self.relayTask = task
        RelayDelegate.shared.register(task: task, protocolInstance: self)
        task.resume()
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

    func register(task: URLSessionTask, protocolInstance: MapleURLProtocol) {
        lock.lock(); defer { lock.unlock() }
        handlers[task.taskIdentifier] = protocolInstance
    }

    func unregister(task: URLSessionTask) {
        lock.lock(); defer { lock.unlock() }
        handlers.removeValue(forKey: task.taskIdentifier)
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
