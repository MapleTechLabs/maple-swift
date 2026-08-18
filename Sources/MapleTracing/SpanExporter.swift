import Foundation
import MapleCore

/// Ships spans to `POST {endpoint}/v1/traces` as gzipped OTLP/JSON.
///
/// Same posture as replay upload: best-effort, never retried. A `402` disables export for
/// the process — the org's entitlement is denied and every further POST is waste on the
/// device and at the gateway alike.
final class SpanExporter: @unchecked Sendable {
    private let poster: IngestPoster
    private let resource: [String: AttributeValue]
    private let lock = NSLock()
    private var stopped = false

    /// Gateway body limit. A body over this is rejected before it is read, so there is no
    /// point spending the upload.
    static let maxBodyBytes = 20 * 1024 * 1024

    init(options: TracingOptions, ingestKey: String, urlSession: URLSession? = nil) {
        self.poster = IngestPoster(
            endpoint: options.endpoint,
            ingestKey: ingestKey,
            subsystem: "MapleTracing",
            urlSession: urlSession
        )
        self.resource = ResourceAttributes.build(options: options)
    }

    /// The URL this exporter posts to. The URLSession instrumentation reads it so the
    /// exporter is never traced by the tracer it exports for — without that, one export
    /// produces a span, which produces an export, forever.
    var tracesURL: URL { poster.url(for: "/v1/traces") }

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func export(_ spans: [SpanData], completion: (() -> Void)? = nil) {
        guard !spans.isEmpty, !isStopped else { completion?(); return }

        let body: Data
        do {
            let json = try OTLPEncoder.encode(spans: spans, resource: resource)
            guard let gzipped = Gzip.compress(json) else {
                MapleLog.warnOnce("MapleTracing", "traces", "gzip failed; \(spans.count) spans dropped")
                completion?()
                return
            }
            body = gzipped
        } catch {
            MapleLog.warnOnce("MapleTracing", "traces encode", error)
            completion?()
            return
        }

        guard body.count <= Self.maxBodyBytes else {
            MapleLog.warnOnce(
                "MapleTracing",
                "traces",
                "\(body.count)-byte batch is over the \(Self.maxBodyBytes)-byte gateway limit; dropped"
            )
            completion?()
            return
        }

        poster.post(
            path: "/v1/traces",
            body: body,
            contentType: "application/json",
            // The gzip here *is* a transfer encoding, unlike a replay blob where the
            // gzip is the stored payload. The gateway inflates it before parsing.
            headers: ["Content-Encoding": "gzip"],
            what: "traces"
        ) { [weak self] outcome in
            switch outcome {
            case .entitlementDenied:
                guard let self else { break }
                self.lock.lock()
                let alreadyStopped = self.stopped
                self.stopped = true
                self.lock.unlock()
                if !alreadyStopped {
                    MapleLog.notice("MapleTracing", "ingest refused by entitlement (402); trace export disabled")
                }
            case .budgetExhausted:
                // 413 has no per-session meaning for traces the way it does for replay
                // chunks; the batch was simply too big. Halving it would be a retry, and
                // there are no retries here.
                MapleLog.warnOnce("MapleTracing", "traces", "413; batch dropped")
            case .delivered, .throttled, .dropped:
                break
            }
            completion?()
        }
    }

    func awaitPending(timeout: TimeInterval, completion: @escaping () -> Void) {
        poster.awaitPending(timeout: timeout, completion: completion)
    }
}
