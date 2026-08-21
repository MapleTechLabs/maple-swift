import MapleCore
import XCTest
@testable import MapleTracing

/// Does the interception actually fire?
///
/// Every other test in this target asserts what the SDK *builds*. This one asserts what
/// leaves the process, through `URLSession.shared`, with the real swizzle installed —
/// which is the only thing that can catch "the header is correct and never sent". It
/// exists because that is exactly what happened: the first end-to-end run produced
/// perfect spans and not one `traceparent` on the wire.
final class URLSessionInstrumentationTests: XCTestCase {
    private static let target = URL(string: "https://backend.test/orders")!
    private static let payload = Data("{\"device\":\"abc\"}".utf8)

    private static func post(body: Data?) -> URLRequest {
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.httpBody = body
        return request
    }

    override func setUp() {
        super.setUp()
        SessionSink.shared.resetForTesting()
        RecordingProtocol.seen = []
        // The interceptor re-issues each request through its own session, which does not
        // see globally-registered protocols — so the stub goes there, not on the global
        // list, and what it records is genuinely what left the interceptor.
        MapleURLProtocol.relayProtocolClassesForTesting = [RecordingProtocol.self]

        var options = TracingOptions()
        options.ingestKey = "maple_pk_test"
        options.endpoint = URL(string: "https://ingest.maple.dev")!
        options.instrumentURLSession = .automatic
        options.instrumentViewControllers = false
        MapleTracing.shared.stop()
        MapleTracing.shared.start(options: options)
    }

    override func tearDown() {
        MapleTracing.shared.stop()
        MapleURLProtocol.relayProtocolClassesForTesting = []
        SessionSink.shared.resetForTesting()
        super.tearDown()
    }

    private func assertPropagated(_ line: UInt = #line) throws {
        let recorded = try XCTUnwrap(RecordingProtocol.seen.last, "no request reached the transport", line: line)
        let header = try XCTUnwrap(
            recorded.request.value(forHTTPHeaderField: "traceparent"),
            "traceparent was not injected — this URLSession API is not intercepted",
            line: line
        )
        XCTAssertNotNil(SpanContext.parse(traceParent: header), line: line)
    }

    private func assertBodyDelivered(_ expected: Data, _ line: UInt = #line) throws {
        let recorded = try XCTUnwrap(RecordingProtocol.seen.last, "no request reached the transport", line: line)
        XCTAssertEqual(recorded.body, expected, "the relay changed the request body", line: line)
    }

    func testCompletionHandlerAPIIsInstrumented() throws {
        let done = expectation(description: "request")
        URLSession.shared.dataTask(with: Self.target) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try assertPropagated()
    }

    func testRequestCompletionHandlerAPIIsInstrumented() throws {
        let done = expectation(description: "request")
        URLSession.shared.dataTask(with: URLRequest(url: Self.target)) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try assertPropagated()
    }

    func testDelegateStyleTaskIsInstrumented() throws {
        let task = URLSession.shared.dataTask(with: Self.target)
        task.resume()
        // No handler to wait on; the KVO observer is what closes the span.
        let done = expectation(description: "request")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done.fulfill() }
        wait(for: [done], timeout: 5)
        try assertPropagated()
    }

    /// The API most modern apps actually call.
    func testAsyncAwaitAPIIsInstrumented() async throws {
        _ = try? await URLSession.shared.data(from: Self.target)
        try assertPropagated()
    }

    // MARK: - Requests with a body

    /// Every one of these was untraced until the body-carrying relay landed: Foundation
    /// hands a protocol the body as a stream, and the interceptor declined streams — so a
    /// whole app's writes shipped no `traceparent` while its reads looked perfect.
    /// One case per way `URLSession` can be handed a body, each asserting both halves.

    func testPOSTWithHTTPBodyIsInstrumented() throws {
        let done = expectation(description: "request")
        URLSession.shared.dataTask(with: Self.post(body: Self.payload)) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try assertPropagated()
        try assertBodyDelivered(Self.payload)
    }

    func testAsyncPOSTWithHTTPBodyIsInstrumented() async throws {
        _ = try? await URLSession.shared.data(for: Self.post(body: Self.payload))
        try assertPropagated()
        try assertBodyDelivered(Self.payload)
    }

    func testUploadTaskFromDataIsInstrumented() throws {
        let done = expectation(description: "request")
        URLSession.shared.uploadTask(with: Self.post(body: nil), from: Self.payload) { _, _, _ in
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        try assertPropagated()
        try assertBodyDelivered(Self.payload)
    }

    func testAsyncUploadIsInstrumented() async throws {
        _ = try? await URLSession.shared.upload(for: Self.post(body: nil), from: Self.payload)
        try assertPropagated()
        try assertBodyDelivered(Self.payload)
    }

    /// The shape `swift-openapi-urlsession` uses for every request that has a body, and so
    /// the shape every write from the iOS app takes. Its length is undeclared, which is the
    /// case the relay hands on as a stream rather than buffering.
    func testStreamedUploadIsInstrumented() throws {
        let delegate = StreamedBodyDelegate(payload: Self.payload)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.uploadTask(withStreamedRequest: Self.post(body: nil)).resume()
        wait(for: [delegate.finished], timeout: 5)
        try assertPropagated()
        try assertBodyDelivered(Self.payload)
    }

    /// Past the buffering ceiling the body is handed on by reference. It must still arrive
    /// whole — losing an upload to gain a span is never the right trade.
    func testBodyBeyondTheBufferingCeilingIsDeliveredIntact() throws {
        let large = Data(repeating: 0x41, count: 2 * 1_048_576)
        let done = expectation(description: "request")
        URLSession.shared.uploadTask(with: Self.post(body: nil), from: large) { _, _, _ in done.fulfill() }
            .resume()
        wait(for: [done], timeout: 20)
        try assertBodyDelivered(large)
    }

    /// One request, one client span — the interceptor must not re-enter itself now that it
    /// re-issues body-bearing requests too.
    func testBodyBearingRequestProducesExactlyOneRequestOnTheWire() throws {
        let done = expectation(description: "request")
        URLSession.shared.dataTask(with: Self.post(body: Self.payload)) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(RecordingProtocol.seen.count, 1)
    }

    func testSDKOwnRequestsAreNotTraced() {
        var request = URLRequest(url: URL(string: "https://ingest.maple.dev/v1/traces")!)
        request.setValue(MapleSDK.hint, forHTTPHeaderField: MapleSDK.hintHeader)
        XCTAssertFalse(MapleTracing.shared.shouldTrace(request))
    }
}

/// Answers every request locally and keeps what it was given — headers *and* body.
///
/// The body half is not decoration. A header assertion alone passed for the entire time
/// every POST in the SDK went untraced, because the request that carried the header never
/// reached this far; and a body assertion alone would miss a trace that quietly breaks in
/// two. Both, per request, is the only pair that catches either.
final class RecordingProtocol: URLProtocol {
    struct Recorded {
        let request: URLRequest
        let body: Data?
    }

    nonisolated(unsafe) static var seen: [Recorded] = []

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "backend.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.seen.append(Recorded(request: request, body: request.httpBody ?? Self.drain(request.httpBodyStream)))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Parenting is a separate failure mode from propagation, and it fails silently: the
/// header is present and well-formed, it just names a trace nobody else is in. Two
/// requests inside one flow came back with two unrelated trace ids the first time this
/// went end to end.
final class ClientSpanParentingTests: XCTestCase {
    private static let target = URL(string: "https://backend.test/orders")!

    override func setUp() {
        super.setUp()
        RecordingProtocol.seen = []
        MapleURLProtocol.relayProtocolClassesForTesting = [RecordingProtocol.self]
        var options = TracingOptions()
        options.ingestKey = "maple_pk_test"
        options.endpoint = URL(string: "https://ingest.maple.dev")!
        options.instrumentURLSession = .automatic
        options.instrumentViewControllers = false
        MapleTracing.shared.stop()
        MapleTracing.shared.start(options: options)
    }

    override func tearDown() {
        MapleTracing.shared.stop()
        MapleURLProtocol.relayProtocolClassesForTesting = []
        super.tearDown()
    }

    private func sentTraceIds() -> [String] {
        RecordingProtocol.seen.compactMap { recorded -> String? in
            guard let header = recorded.request.value(forHTTPHeaderField: "traceparent"),
                  let context = SpanContext.parse(traceParent: header) else { return nil }
            return context.traceId.hex
        }
    }

    func testRequestsInsideOneSpanShareItsTrace() async throws {
        let traceId: String? = await MapleTracing.shared.span("checkout") { span in
            _ = try? await URLSession.shared.data(from: Self.target)
            _ = try? await URLSession.shared.data(from: Self.target.appendingPathComponent("submit"))
            return span?.traceId
        }
        let sent = sentTraceIds()
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(Set(sent).count, 1, "both requests must be in one trace")
        XCTAssertEqual(sent.first, traceId, "and it must be the enclosing span's trace")
    }

    func testRequestOutsideAnySpanStartsItsOwnTrace() async throws {
        _ = try? await URLSession.shared.data(from: Self.target)
        XCTAssertEqual(sentTraceIds().count, 1)
    }
}


/// Feeds a body the way `swift-openapi-urlsession` does: no declared length, the stream
/// handed over on demand.
private final class StreamedBodyDelegate: NSObject, URLSessionTaskDelegate {
    let finished = XCTestExpectation(description: "streamed upload")
    private let payload: Data

    init(payload: Data) { self.payload = payload }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void
    ) {
        completionHandler(InputStream(data: payload))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finished.fulfill()
    }
}
