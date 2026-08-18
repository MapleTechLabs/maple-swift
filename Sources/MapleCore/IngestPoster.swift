import Foundation

/// One POST to the Maple ingest gateway, and the entire retry policy for it.
///
/// **There is no retry policy.** The gateway assumes a client drops on non-2xx and says
/// so in the handler — `413` *is* "this session blew its byte ceiling, stop", and `429`
/// is backpressure. Retrying either is arguing with a server that is telling you to go
/// away. So every failure drops the payload, and the only thing a response can change is
/// whether the caller stops sending altogether.
///
/// Shared by replay upload and trace export because the two want identical plumbing and
/// genuinely different policy: replay stops uploading *chunks* on 413 but keeps posting
/// metadata, tracing has no such distinction. The policy therefore stays with the caller,
/// which is what `Outcome` is for.
public final class IngestPoster: @unchecked Sendable {
    /// What a response means, stripped of the caller's policy.
    public enum Outcome: Equatable, Sendable {
        /// 2xx.
        case delivered
        /// 413 — the per-session decompressed-byte budget is spent. Not transient.
        case budgetExhausted
        /// 402 — nothing from this org is being accepted. Continuing to POST is waste.
        case entitlementDenied
        /// 429 — backpressure.
        case throttled
        /// Anything else, including transport failures.
        case dropped(String)
    }

    private let endpoint: URL
    private let ingestKey: String
    private let subsystem: String
    private let urlSession: URLSession

    /// In-flight requests. `awaitPending` is what lets a `UIApplication` background task
    /// hold the app awake for exactly as long as the final flush needs.
    private let pending = DispatchGroup()

    public init(endpoint: URL, ingestKey: String, subsystem: String, urlSession: URLSession? = nil) {
        self.endpoint = endpoint
        self.ingestKey = ingestKey
        self.subsystem = subsystem
        self.urlSession = urlSession ?? Self.defaultURLSession()
    }

    public static func defaultURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Telemetry is never worth stalling behind: a request that has not completed in
        // 15s has missed its moment, and holding it open only delays the background task
        // that is waiting on it.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // Off by default: a request parked waiting for connectivity outlives the session
        // it belongs to, and stale telemetry is worth less than a fast drop.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Build the request this poster would send. Exposed so the URLSession
    /// instrumentation can recognise the SDK's own traffic and leave it alone — an
    /// exporter that traces its own exports produces a span per span, forever.
    public func request(path: String, contentType: String, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // Recorded by ingest as `maple.sdk`, which is how a mobile session is told apart
        // from a browser one without guessing from `os_name`.
        request.setValue(MapleSDK.hint, forHTTPHeaderField: MapleSDK.hintHeader)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    public func post(
        path: String,
        body: Data,
        contentType: String,
        headers: [String: String] = [:],
        what: String,
        completion: ((Outcome) -> Void)? = nil
    ) {
        var request = self.request(path: path, contentType: contentType, headers: headers)
        request.httpBody = body

        pending.enter()
        let task = urlSession.dataTask(with: request) { [weak self] _, response, error in
            var outcome = Outcome.delivered
            defer {
                self?.pending.leave()
                completion?(outcome)
            }
            if let error {
                MapleLog.warnOnce(self?.subsystem ?? "Maple", what, error)
                outcome = .dropped("\(error)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200...299:
                outcome = .delivered
            case 402:
                outcome = .entitlementDenied
            case 413:
                outcome = .budgetExhausted
            case 429:
                // Dropping is the contract — a retry is more load aimed at a server that
                // just asked for less.
                MapleLog.warnOnce(self?.subsystem ?? "Maple", what, "429 backpressure; payload dropped")
                outcome = .throttled
            default:
                MapleLog.warnOnce(self?.subsystem ?? "Maple", what, "HTTP \(status)")
                outcome = .dropped("HTTP \(status)")
            }
        }
        task.resume()
    }

    /// Run `completion` once every in-flight request has finished, or `timeout` elapses.
    ///
    /// The timeout is not optional politeness: this is called while holding a
    /// `UIApplication` background task, and the OS kills the app outright if that task is
    /// not ended in time. Better to give up on a payload than to be terminated.
    public func awaitPending(timeout: TimeInterval, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [pending] in
            _ = pending.wait(timeout: .now() + timeout)
            completion()
        }
    }

    public func url(for path: String) -> URL {
        // Tolerate a configured endpoint with a trailing slash rather than producing
        // `https://host//v1/…`, which some proxies normalise and some 404.
        var base = endpoint.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? endpoint
    }
}
