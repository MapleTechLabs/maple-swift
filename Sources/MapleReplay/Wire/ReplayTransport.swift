import Foundation

/// Why an ingest key was refused before a single request was made.
///
/// Checked client-side because the alternative is a silent recording: the gateway
/// answers a bad key with 401 on every POST, and a best-effort transport by definition
/// swallows that. Better to refuse at `start()`, where a developer is looking.
public enum IngestKeyProblem: Equatable, Sendable, CustomStringConvertible {
    case missing
    case wrongPrefix

    public var description: String {
        switch self {
        case .missing:
            return "ReplayOptions.ingestKey is not set. Set it to your public ingest key (maple_pk_…)."
        case .wrongPrefix:
            return "ReplayOptions.ingestKey must start with maple_pk_ (or maple_sk_). The gateway rejects anything else with 401."
        }
    }
}

/// The three `POST`s that make up session replay ingestion.
///
/// One transport instance per session: the `413`/`402` kill switches below are
/// per-session state, and a rotated session id must start with them clear.
///
/// **No retries, by design.** The gateway assumes a client drops on non-2xx and says so
/// in the handler — `413` *is* "this session blew its byte ceiling, stop", and `429` is
/// backpressure. Retrying either is arguing with a server that is telling you to go away.
/// So every failure drops the payload, and the only state a response can change is
/// whether we stop sending altogether.
final class ReplayTransport {
    /// Gateway body limit. A body over this is rejected with 413 before it is read, so
    /// there is no point spending the upload; drop it here and say so.
    static let maxBodyBytes = 20 * 1024 * 1024

    /// The gateway's drop-everything token. Authenticates, stores nothing, meters
    /// nothing — useful for pointing a build at a local gateway without a real key.
    static let sentinelKey = "MAPLE_TEST"

    private let endpoint: URL
    private let ingestKey: String
    private let sessionId: String
    private let urlSession: URLSession

    /// In-flight requests. `awaitPending` is what lets a background task hold the app
    /// awake exactly as long as the final flush needs.
    private let pending = DispatchGroup()

    private let lock = NSLock()
    private var blobsStopped = false
    private var allStopped = false

    init(endpoint: URL, ingestKey: String, sessionId: String, urlSession: URLSession? = nil) {
        self.endpoint = endpoint
        self.ingestKey = ingestKey
        self.sessionId = sessionId
        self.urlSession = urlSession ?? Self.defaultURLSession()
    }

    private static func defaultURLSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        // Replay is never worth stalling behind: a request that has not completed in
        // 15s has missed its moment, and holding it open only delays the background
        // task that is waiting on it.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // Off by default: a request parked waiting for connectivity outlives the
        // session it belongs to, and a stale chunk is worth less than a fast drop.
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    // MARK: - Key validation

    /// Mirrors `infer_ingest_key_type` at the gateway: anything not prefixed
    /// `maple_pk_`/`maple_sk_` resolves to no key at all and comes back 401.
    static func validate(ingestKey: String?) -> IngestKeyProblem? {
        guard let key = ingestKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return .missing
        }
        if key == sentinelKey { return nil }
        guard key.hasPrefix("maple_pk_") || key.hasPrefix("maple_sk_") else { return .wrongPrefix }
        return nil
    }

    // MARK: - The three POSTs

    /// `POST /v1/sessionReplays/meta` — NDJSON, one row.
    ///
    /// This is the **billed** unit and the only thing that makes a session exist in the
    /// UI; blobs are not metered. It is therefore the one request that keeps going after
    /// a `413`: a session that blew its byte ceiling still has to end cleanly.
    func postMeta(_ row: SessionMetaRow, now: Date = Date(), completion: (() -> Void)? = nil) {
        guard !isAllStopped else { completion?(); return }
        do {
            let body = try row.ndjson(now: now)
            post(
                path: "/v1/sessionReplays/meta",
                body: body,
                contentType: "application/x-ndjson",
                what: "metadata",
                completion: completion
            )
        } catch {
            warnOnce("metadata encode", error)
            completion?()
        }
    }

    /// `POST /v1/sessionReplays/blob` — the gzipped rrweb chunk, verbatim.
    ///
    /// No `Content-Encoding: gzip`. The gzip is the payload, not a transfer encoding —
    /// the gateway inflates it to count decompressed bytes and then stores the original
    /// bytes as-is. Declaring it as an encoding invites a proxy to helpfully undo it.
    func postBlob(_ segment: PreparedSegment, completion: (() -> Void)? = nil) {
        let artifacts = segment.artifacts
        guard !isBlobStopped else { completion?(); return }
        guard segment.body.count <= Self.maxBodyBytes else {
            warnOnce(
                "blob",
                "chunk \(artifacts.chunkSeq) is \(segment.body.count) bytes, over the \(Self.maxBodyBytes)-byte gateway limit; dropped"
            )
            completion?()
            return
        }
        post(
            path: "/v1/sessionReplays/blob",
            body: segment.body,
            contentType: "application/octet-stream",
            headers: SegmentWriter.headers(
                sessionId: sessionId,
                chunkSeq: artifacts.chunkSeq,
                isCheckpoint: artifacts.isCheckpoint,
                eventCount: artifacts.eventCount,
                durationMs: artifacts.durationMs
            ),
            what: "blob",
            completion: completion
        )
    }

    /// `POST /v1/sessionEvents` — distilled events, NDJSON, one row per event.
    func postEvents(_ rows: [SessionEventRow], now: Date = Date(), completion: (() -> Void)? = nil) {
        guard !rows.isEmpty else { completion?(); return }
        guard !isAllStopped else { completion?(); return }
        do {
            var body = Data()
            for row in rows {
                body.append(try row.ndjson())
            }
            post(
                path: "/v1/sessionEvents",
                body: body,
                contentType: "application/x-ndjson",
                what: "events",
                completion: completion
            )
        } catch {
            warnOnce("events encode", error)
            completion?()
        }
    }

    // MARK: - Draining

    /// Run `completion` once every in-flight request has finished, or `timeout` elapses.
    ///
    /// The timeout is not optional politeness: this is called while holding a
    /// `UIApplication` background task, and the OS kills the app outright if that task
    /// is not ended in time. Better to give up on a chunk than to be terminated.
    func awaitPending(timeout: TimeInterval, completion: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async { [pending] in
            _ = pending.wait(timeout: .now() + timeout)
            completion()
        }
    }

    // MARK: - Request plumbing

    private var isAllStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return allStopped
    }

    private var isBlobStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return allStopped || blobsStopped
    }

    private func post(
        path: String,
        body: Data,
        contentType: String,
        headers: [String: String] = [:],
        what: String,
        completion: (() -> Void)?
    ) {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = "POST"
        request.setValue("Bearer \(ingestKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body

        pending.enter()
        let task = urlSession.dataTask(with: request) { [weak self] _, response, error in
            defer {
                self?.pending.leave()
                completion?()
            }
            guard let self else { return }
            if let error {
                self.warnOnce(what, error)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            self.handle(status: status, what: what)
        }
        task.resume()
    }

    /// The whole retry policy, such as it is.
    private func handle(status: Int, what: String) {
        switch status {
        case 200...299:
            return

        case 413:
            // The per-session decompressed-byte budget is spent. Every further chunk is
            // rejected before it is read, so stop producing them. Metadata still goes:
            // the session exists and deserves an `ended` row.
            lock.lock()
            let alreadyStopped = blobsStopped
            blobsStopped = true
            lock.unlock()
            if !alreadyStopped {
                NSLog("[MapleReplay] session \(sessionId) hit its ingest byte ceiling; no further chunks will be uploaded")
            }

        case 402:
            // Entitlement denied — nothing from this org is being accepted. Continuing
            // to POST is pure waste, on the device and at the gateway.
            lock.lock()
            let alreadyStopped = allStopped
            allStopped = true
            lock.unlock()
            if !alreadyStopped {
                NSLog("[MapleReplay] ingest refused by entitlement (402); replay upload disabled for this session")
            }

        case 429:
            // Backpressure. Dropping is the contract — a retry is more load aimed at a
            // server that just asked for less.
            warnOnce(what, "429 backpressure; chunk dropped")

        default:
            warnOnce(what, "HTTP \(status)")
        }
    }

    private func url(for path: String) -> URL {
        // Tolerate a configured endpoint with a trailing slash rather than producing
        // `https://host//v1/…`, which some proxies normalise and some 404.
        var base = endpoint.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path) ?? endpoint
    }

    // MARK: - Warning

    // Upload is best-effort and must never throw into the host app, but a wholly broken
    // endpoint should not be *silent*. Warn at most once every 30s — the same budget the
    // browser SDK uses — so a misconfiguration is visible without flooding the log.
    private static let warnLock = NSLock()
    private static var lastWarnAt = Date.distantPast

    private func warnOnce(_ what: String, _ reason: Any) {
        Self.warnLock.lock()
        let now = Date()
        let shouldWarn = now.timeIntervalSince(Self.lastWarnAt) >= 30
        if shouldWarn { Self.lastWarnAt = now }
        Self.warnLock.unlock()

        guard shouldWarn else { return }
        NSLog("[MapleReplay] session replay \(what) POST failed (dropping, no retry): \(reason)")
    }
}
