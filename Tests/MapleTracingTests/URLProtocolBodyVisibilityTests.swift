import XCTest

/// What does a `URLProtocol` actually see of a request body?
///
/// The interceptor re-issues every request it traces, so it can only trace a request whose
/// body it can reproduce. `MapleURLProtocol.canInit` decides that from the `URLRequest` it
/// is handed — but *what Foundation puts in that request* differs per `URLSession`
/// task-creation API, and guessing wrong is how every POST in an app ends up untraced
/// while the SDK looks healthy.
///
/// This file involves no Maple code at all. It is a table of Foundation's behaviour, one
/// row per creation API, so the interception rules can be written against measured facts
/// instead of folklore. When Foundation changes, this fails first and names the row.
final class URLProtocolBodyVisibilityTests: XCTestCase {
    private static let target = URL(string: "https://probe.test/orders")!
    private let payload = Data("{\"device\":\"abc\"}".utf8)

    override func setUp() {
        super.setUp()
        BodyProbeProtocol.reset()
    }

    // MARK: - Data tasks

    func testDataTaskWithSmallBody() throws {
        let done = expectation(description: "request")
        session().dataTask(with: request(body: payload)) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try report("dataTask(with:) + httpBody, small", expecting: payload)
    }

    /// Foundation is known to treat small and large bodies differently — a rule inferred
    /// from a 16-byte payload is not a rule.
    func testDataTaskWithLargeBody() throws {
        let large = Data(repeating: 0x41, count: 1_048_576)
        let done = expectation(description: "request")
        session().dataTask(with: request(body: large)) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 15)
        try report("dataTask(with:) + httpBody, 1MiB", expecting: large)
    }

    func testAsyncDataForRequestWithBody() async throws {
        _ = try? await session().data(for: request(body: payload))
        try report("data(for:) + httpBody", expecting: payload)
    }

    // MARK: - Upload tasks

    func testUploadTaskFromData() throws {
        let done = expectation(description: "request")
        session().uploadTask(with: request(body: nil), from: payload) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try report("uploadTask(with:from:)", expecting: payload)
    }

    func testUploadTaskFromFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe-body.json")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let done = expectation(description: "request")
        session().uploadTask(with: request(body: nil), fromFile: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try report("uploadTask(with:fromFile:)", expecting: payload)
    }

    func testAsyncUploadForFrom() async throws {
        _ = try? await session().upload(for: request(body: nil), from: payload)
        try report("upload(for:from:)", expecting: payload)
    }

    /// The API `swift-openapi-urlsession` uses for every request that has a body — which is
    /// every POST, PUT and PATCH the iOS app makes.
    func testUploadTaskWithStreamedRequest() throws {
        let delegate = StreamingBodyDelegate(payload: payload)
        let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        // Probe C: does a `URLProtocol` property set before task creation survive to `canInit`?
        let outgoing = (request(body: nil) as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: BodyProbeProtocol.markerKey, in: outgoing)

        session.uploadTask(withStreamedRequest: outgoing as URLRequest).resume()
        wait(for: [delegate.finished], timeout: 5)
        try report("uploadTask(withStreamedRequest:)", expecting: payload)
    }

    /// The same API with a body far past any sane buffering cap: can the size be known
    /// before the stream is read?
    func testUploadTaskWithLargeStreamedRequest() throws {
        let large = Data(repeating: 0x42, count: 4 * 1_048_576)
        let delegate = StreamingBodyDelegate(payload: large)
        let session = URLSession(configuration: configuration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.uploadTask(withStreamedRequest: request(body: nil)).resume()
        wait(for: [delegate.finished], timeout: 20)
        try report("uploadTask(withStreamedRequest:), 4MiB", expecting: large)
    }

    // MARK: - Harness

    private func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BodyProbeProtocol.self]
        return configuration
    }

    private func session() -> URLSession { URLSession(configuration: configuration()) }

    private func request(body: Data?) -> URLRequest {
        var request = URLRequest(url: Self.target)
        request.httpMethod = "POST"
        request.httpBody = body
        return request
    }

    /// Prints the row and asserts the one thing that matters: an interceptor handed this
    /// request could reproduce the body. A failure here is a finding, not a flake — it
    /// names an API whose body is invisible below `URLSession`.
    private func report(_ api: String, expecting body: Data, line: UInt = #line) throws {
        let record = try XCTUnwrap(BodyProbeProtocol.records.last, "no request reached the protocol", line: line)
        print("""
            [body-visibility] \(api): \
            httpBody=\(record.hadHTTPBody) stream=\(record.hadBodyStream) \
            bytes=\(record.body?.count.description ?? "nil") \
            canInit(task:)=\(record.canInitWithTaskFired) task=\(record.taskClass ?? "nil") \
            marker=\(record.markerSurvived) expectedToSend=\(record.expectedToSend) \
            contentLength=\(record.contentLength ?? "nil")
            """)
        XCTAssertEqual(record.body, body, "\(api): body not reproducible from the request", line: line)
    }
}

/// Answers every request locally and records what it was handed.
final class BodyProbeProtocol: URLProtocol {
    struct Record {
        let hadHTTPBody: Bool
        let hadBodyStream: Bool
        let body: Data?
        let canInitWithTaskFired: Bool
        let taskClass: String?
        let markerSurvived: Bool
        /// The two signals available *before* the stream is touched — the only basis on
        /// which a size cap can be applied, since a stream cannot be un-consumed.
        let expectedToSend: Int64
        let contentLength: String?
    }

    static let markerKey = "dev.maple.probe.marker"

    nonisolated(unsafe) static var records: [Record] = []
    nonisolated(unsafe) private static var sawCanInitWithTask = false
    nonisolated(unsafe) private static var lastTaskClass: String?
    nonisolated(unsafe) private static var lastExpectedToSend: Int64 = -999

    static func reset() {
        records = []
        sawCanInitWithTask = false
        lastTaskClass = nil
        lastExpectedToSend = -999
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    /// `URLSession` prefers this overload when it is implemented. Whether it does is itself
    /// a measurement — it is the only hook that can tell an upload task from a data task.
    override class func canInit(with task: URLSessionTask) -> Bool {
        sawCanInitWithTask = true
        lastTaskClass = String(describing: type(of: task))
        lastExpectedToSend = task.countOfBytesExpectedToSend
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.records.append(
            Record(
                hadHTTPBody: request.httpBody != nil,
                hadBodyStream: request.httpBodyStream != nil,
                body: request.httpBody ?? Self.drain(request.httpBodyStream),
                canInitWithTaskFired: Self.sawCanInitWithTask,
                taskClass: Self.lastTaskClass,
                markerSurvived: Self.property(forKey: Self.markerKey, in: request) != nil,
                expectedToSend: Self.lastExpectedToSend,
                contentLength: request.value(forHTTPHeaderField: "Content-Length")
            )
        )
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

/// Feeds a body stream the way `swift-openapi-urlsession` does.
private final class StreamingBodyDelegate: NSObject, URLSessionTaskDelegate {
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
