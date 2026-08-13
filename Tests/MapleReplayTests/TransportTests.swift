import XCTest
@testable import MapleReplay

/// Captures the requests a `ReplayTransport` makes and answers them with a canned status.
///
/// A stub rather than a live server because the assertions here are about the *shape* of
/// the request — headers, content types, the exact bytes — which is what the gateway
/// rejects on, and which no amount of "it returned 200" would catch.
private final class StubProtocol: URLProtocol {
    struct Recorded {
        let url: URL
        let method: String
        let headers: [String: String]
        let body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var statusQueue: [Int] = []
    nonisolated(unsafe) private static var defaultStatus = 200

    static func reset(defaultStatus status: Int = 200, statuses: [Int] = []) {
        lock.lock(); defer { lock.unlock() }
        recorded = []
        statusQueue = statuses
        defaultStatus = status
    }

    static var requests: [Recorded] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func requests(toPath path: String) -> [Recorded] {
        requests.filter { $0.url.path == path }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession moves a large `httpBody` onto `httpBodyStream` by the time a
        // protocol sees it, so both have to be read or the body assertions silently
        // compare against nothing.
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                body.append(contentsOf: buffer[0..<read])
            }
            stream.close()
        }

        Self.lock.lock()
        Self.recorded.append(
            Recorded(
                url: request.url!,
                method: request.httpMethod ?? "",
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            )
        )
        let status = Self.statusQueue.isEmpty ? Self.defaultStatus : Self.statusQueue.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class IngestKeyValidationTests: XCTestCase {
    /// Mirrors `infer_ingest_key_type` at the gateway: a key with any other prefix
    /// resolves to no key at all and every request comes back 401 — invisibly, behind a
    /// transport whose whole contract is to swallow failures.
    func testOnlyMapleKeyPrefixesAreAccepted() {
        XCTAssertNil(ReplayTransport.validate(ingestKey: "maple_pk_abc123"))
        XCTAssertNil(ReplayTransport.validate(ingestKey: "maple_sk_abc123"))
        XCTAssertNil(ReplayTransport.validate(ingestKey: ReplayTransport.sentinelKey))

        XCTAssertEqual(ReplayTransport.validate(ingestKey: nil), .missing)
        XCTAssertEqual(ReplayTransport.validate(ingestKey: ""), .missing)
        XCTAssertEqual(ReplayTransport.validate(ingestKey: "   "), .missing)
        XCTAssertEqual(ReplayTransport.validate(ingestKey: "abc123"), .wrongPrefix)
        XCTAssertEqual(ReplayTransport.validate(ingestKey: "Bearer maple_pk_abc"), .wrongPrefix)
    }
}

final class ReplayTransportTests: XCTestCase {
    private var transport: ReplayTransport!

    private func makeTransport(
        endpoint: String = "https://ingest.example.test",
        sessionId: String = "session-1"
    ) -> ReplayTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return ReplayTransport(
            endpoint: URL(string: endpoint)!,
            ingestKey: "maple_pk_test",
            sessionId: sessionId,
            urlSession: URLSession(configuration: configuration)
        )
    }

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
        transport = makeTransport()
    }

    /// Waits for every request the transport has started, so assertions never race the
    /// completion handlers.
    private func drain(_ transport: ReplayTransport, file: StaticString = #filePath, line: UInt = #line) {
        let finished = expectation(description: "requests settled")
        transport.awaitPending(timeout: 5) { finished.fulfill() }
        wait(for: [finished], timeout: 6)
    }

    private func segment(chunkSeq: Int = 0, body: Data = Data("gzipped".utf8)) -> PreparedSegment {
        PreparedSegment(
            artifacts: SegmentArtifacts(
                chunkSeq: chunkSeq,
                isCheckpoint: true,
                gzippedBytes: body.count,
                rawJSONBytes: 100,
                videoBytes: 50,
                frameCount: 5,
                eventCount: 4,
                durationMs: 5_000,
                chunkURL: nil,
                videoURL: nil
            ),
            body: body
        )
    }

    private func metaRow(status: SessionMetaRow.Status = .active) -> SessionMetaRow {
        SessionMetaRow(
            sessionId: "session-1",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            status: status,
            version: status == .active ? 1 : 2,
            serviceName: "tests",
            environment: "test",
            userId: "",
            recorded: true
        )
    }

    // MARK: - Request shape

    func testBlobPostMatchesTheGatewayContract() throws {
        let body = Data("pretend this is gzip".utf8)
        transport.postBlob(segment(chunkSeq: 3, body: body))
        drain(transport)

        let request = try XCTUnwrap(StubProtocol.requests(toPath: "/v1/sessionReplays/blob").first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://ingest.example.test/v1/sessionReplays/blob")
        XCTAssertEqual(request.headers["Authorization"], "Bearer maple_pk_test")
        XCTAssertEqual(request.headers["Content-Type"], "application/octet-stream")
        XCTAssertEqual(request.headers["x-maple-session-id"], "session-1")
        XCTAssertEqual(request.headers["x-maple-chunk-seq"], "3")
        XCTAssertEqual(request.headers["x-maple-is-checkpoint"], "1")
        XCTAssertEqual(request.headers["x-maple-event-count"], "4")
        XCTAssertEqual(request.headers["x-maple-duration-ms"], "5000")

        // The gzip is the payload, not a transfer encoding. Declaring it as one invites a
        // proxy to inflate it in transit, and the gateway stores the body verbatim.
        XCTAssertNil(request.headers["Content-Encoding"])
        XCTAssertEqual(request.body, body, "the body is the chunk's bytes, untouched")
    }

    func testMetaPostIsOneNewlineTerminatedNDJSONRow() throws {
        transport.postMeta(metaRow())
        drain(transport)

        let request = try XCTUnwrap(StubProtocol.requests(toPath: "/v1/sessionReplays/meta").first)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-ndjson")
        XCTAssertEqual(request.body.last, 0x0A)

        let row = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body.dropLast()) as? [String: Any]
        )
        XCTAssertEqual(row["session_id"] as? String, "session-1")
        XCTAssertEqual(row["status"] as? String, "active")
        XCTAssertEqual(row["version"] as? Int, 1)
    }

    func testSessionEventsPostIsOneRowPerLine() throws {
        transport.postEvents([
            SessionEventRow(sessionId: "session-1", seq: 0, type: .custom, message: "checkout"),
            SessionEventRow(sessionId: "session-1", seq: 1, type: .custom, message: "purchase"),
        ])
        drain(transport)

        let request = try XCTUnwrap(StubProtocol.requests(toPath: "/v1/sessionEvents").first)
        XCTAssertEqual(request.headers["Content-Type"], "application/x-ndjson")

        let lines = request.body.split(separator: 0x0A)
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0])) as? [String: Any])
        XCTAssertEqual(first["type"] as? String, "custom")
        XCTAssertEqual(first["message"] as? String, "checkout")
        XCTAssertEqual(first["seq"] as? Int, 0)
    }

    func testEmptyEventBatchSendsNothing() {
        transport.postEvents([])
        drain(transport)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testTrailingSlashOnTheEndpointDoesNotDoubleUp() throws {
        let transport = makeTransport(endpoint: "https://ingest.example.test/")
        transport.postMeta(metaRow())
        drain(transport)

        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url.absoluteString, "https://ingest.example.test/v1/sessionReplays/meta")
    }

    // MARK: - Response handling
    //
    // The gateway assumes a client drops on non-2xx and comments as much; the browser SDK
    // never retries. These tests pin the two statuses that mean more than "dropped".

    func test413StopsUploadingChunksForTheSessionButNotMetadata() throws {
        StubProtocol.reset(defaultStatus: 413)
        let transport = makeTransport()

        transport.postBlob(segment(chunkSeq: 0))
        drain(transport)
        XCTAssertEqual(StubProtocol.requests(toPath: "/v1/sessionReplays/blob").count, 1)

        // Budget exhausted: every further chunk is rejected before it is even read, so
        // sending them is pure waste on a metered radio.
        transport.postBlob(segment(chunkSeq: 1))
        transport.postBlob(segment(chunkSeq: 2))
        drain(transport)
        XCTAssertEqual(StubProtocol.requests(toPath: "/v1/sessionReplays/blob").count, 1)

        // The metadata row is the billed unit and the only thing that makes the session
        // exist in the UI. A truncated session still has to end cleanly.
        transport.postMeta(metaRow(status: .ended))
        drain(transport)
        XCTAssertEqual(StubProtocol.requests(toPath: "/v1/sessionReplays/meta").count, 1)
    }

    func test402StopsEverything() {
        StubProtocol.reset(defaultStatus: 402)
        let transport = makeTransport()

        transport.postMeta(metaRow())
        drain(transport)
        XCTAssertEqual(StubProtocol.requests.count, 1)

        transport.postBlob(segment())
        transport.postMeta(metaRow(status: .ended))
        transport.postEvents([SessionEventRow(sessionId: "s", seq: 0, type: .custom, message: "x")])
        drain(transport)
        XCTAssertEqual(StubProtocol.requests.count, 1, "entitlement denial ends all uploads")
    }

    func test429AndServerErrorsDropTheChunkWithoutRetryingOrStopping() {
        StubProtocol.reset(defaultStatus: 200, statuses: [429, 500])
        let transport = makeTransport()

        transport.postBlob(segment(chunkSeq: 0))
        drain(transport)
        transport.postBlob(segment(chunkSeq: 1))
        drain(transport)

        // Exactly one request each: backpressure is honoured by dropping, never by
        // retrying at a server that just asked for less load.
        XCTAssertEqual(StubProtocol.requests.count, 2)

        // And neither status is terminal — the next chunk is still attempted.
        transport.postBlob(segment(chunkSeq: 2))
        drain(transport)
        XCTAssertEqual(StubProtocol.requests.count, 3)
    }

    func testChunksOverTheGatewayBodyLimitAreDroppedBeforeTheyAreSent() {
        transport.postBlob(
            segment(body: Data(count: ReplayTransport.maxBodyBytes + 1))
        )
        drain(transport)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "a body the gateway will 413 is not worth the upload")
    }
}
