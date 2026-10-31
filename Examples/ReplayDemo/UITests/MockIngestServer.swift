import Foundation
import Network

/// One request as it arrived, with the status the server answered it with.
struct RecordedRequest {
    let method: String
    let path: String
    /// Names lowercased: HTTP header names are case-insensitive.
    let headers: [String: String]
    let body: Data
    let receivedAt: Date
    let status: Int
}

/// Minimal HTTP/1.1 ingest stand-in, listening on loopback inside the UI test runner.
///
/// The runner and the app are both simulator processes on the host's network stack, so
/// the app reaches this at `http://127.0.0.1:<port>` with no proxy in between: what is
/// recorded here are the exact bytes the SDK put on the wire.
final class MockIngestServer {
    private let queue = DispatchQueue(label: "dev.maple.e2e.mock-ingest")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private let lock = NSLock()
    private var recorded: [RecordedRequest] = []
    private var statusForPath: (String) -> Int = { _ in 200 }

    private(set) var port: UInt16 = 0

    var endpoint: String { "http://127.0.0.1:\(port)" }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)

        let ready = DispatchSemaphore(value: 0)
        var failure: NWError?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 10) == .success else { throw MockServerError.notReady }
        if let failure { throw failure }
        guard let port = listener.port?.rawValue, port != 0 else { throw MockServerError.notReady }
        self.listener = listener
        self.port = port
    }

    func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    /// Decide the status for each request by path. Applies to requests that arrive after
    /// the call.
    func respond(_ status: @escaping (String) -> Int) {
        lock.lock(); defer { lock.unlock() }
        statusForPath = status
    }

    var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.connections[key] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffered: Data())
    }

    /// Keep-alive: parse as many complete requests as the buffer holds, answer each, and
    /// go back to reading, because URLSession reuses connections between POSTs.
    private func receive(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }

            while let (request, consumed) = Self.parse(buffer) {
                buffer = Data(buffer.dropFirst(consumed))
                let status = self.record(request)
                let head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
                connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffered: buffer)
        }
    }

    private func record(_ request: (method: String, path: String, headers: [String: String], body: Data)) -> Int {
        lock.lock(); defer { lock.unlock() }
        let status = statusForPath(request.path)
        recorded.append(
            RecordedRequest(
                method: request.method,
                path: request.path,
                headers: request.headers,
                body: request.body,
                receivedAt: Date(),
                status: status
            )
        )
        return status
    }

    /// One complete request from the front of `buffer`, and how many bytes it used.
    static func parse(_ buffer: Data) -> ((method: String, path: String, headers: [String: String], body: Data), Int)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = buffer.range(of: separator) else { return nil }
        let headBytes = buffer[buffer.startIndex..<headerEnd.lowerBound]
        guard let head = String(data: headBytes, encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buffer.endIndex - bodyStart >= length else { return nil }
        let body = Data(buffer[bodyStart..<(bodyStart + length)])

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? target
        return ((String(requestLine[0]), path, headers, body), bodyStart + length - buffer.startIndex)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 402: return "Payment Required"
        case 413: return "Payload Too Large"
        case 429: return "Too Many Requests"
        default: return "Status"
        }
    }
}

enum MockServerError: Error {
    case notReady
}
