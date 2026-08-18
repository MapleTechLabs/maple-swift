import Foundation
import MapleCore

/// Re-exported so `import MapleReplay` alone still sees the type `start()` reports.
public typealias IngestKeyProblem = MapleCore.IngestKeyProblem

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
///
/// The request plumbing lives in `MapleCore.IngestPoster`, shared with trace export. The
/// *policy* stays here, because the two subsystems genuinely differ: replay stops
/// uploading chunks on 413 while metadata keeps going, and traces have no such split.
final class ReplayTransport {
    /// Gateway body limit. A body over this is rejected with 413 before it is read, so
    /// there is no point spending the upload; drop it here and say so.
    static let maxBodyBytes = 20 * 1024 * 1024

    /// The gateway's drop-everything token. Authenticates, stores nothing, meters
    /// nothing — useful for pointing a build at a local gateway without a real key.
    static let sentinelKey = IngestKey.sentinel

    private let sessionId: String
    private let poster: IngestPoster

    private let lock = NSLock()
    private var blobsStopped = false
    private var allStopped = false

    init(endpoint: URL, ingestKey: String, sessionId: String, urlSession: URLSession? = nil) {
        self.sessionId = sessionId
        self.poster = IngestPoster(
            endpoint: endpoint,
            ingestKey: ingestKey,
            subsystem: "MapleReplay",
            urlSession: urlSession
        )
    }

    // MARK: - Key validation

    /// Mirrors `infer_ingest_key_type` at the gateway: anything not prefixed
    /// `maple_pk_`/`maple_sk_` resolves to no key at all and comes back 401.
    static func validate(ingestKey: String?) -> IngestKeyProblem? {
        IngestKey.validate(ingestKey)
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
            MapleLog.warnOnce("MapleReplay", "metadata encode", error)
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
            MapleLog.warnOnce(
                "MapleReplay",
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
            MapleLog.warnOnce("MapleReplay", "events encode", error)
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
        poster.awaitPending(timeout: timeout, completion: completion)
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
        poster.post(path: path, body: body, contentType: contentType, headers: headers, what: what) { [weak self] outcome in
            self?.handle(outcome)
            completion?()
        }
    }

    /// The whole retry policy, such as it is.
    private func handle(_ outcome: IngestPoster.Outcome) {
        switch outcome {
        case .budgetExhausted:
            // The per-session decompressed-byte budget is spent. Every further chunk is
            // rejected before it is read, so stop producing them. Metadata still goes:
            // the session exists and deserves an `ended` row.
            lock.lock()
            let alreadyStopped = blobsStopped
            blobsStopped = true
            lock.unlock()
            if !alreadyStopped {
                MapleLog.notice("MapleReplay", "session \(sessionId) hit its ingest byte ceiling; no further chunks will be uploaded")
            }

        case .entitlementDenied:
            // Nothing from this org is being accepted. Continuing to POST is pure waste,
            // on the device and at the gateway.
            lock.lock()
            let alreadyStopped = allStopped
            allStopped = true
            lock.unlock()
            if !alreadyStopped {
                MapleLog.notice("MapleReplay", "ingest refused by entitlement (402); replay upload disabled for this session")
            }

        case .delivered, .throttled, .dropped:
            break
        }
    }
}
