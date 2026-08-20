import Foundation

/// How outgoing `URLSession` requests are picked up.
public enum URLSessionInstrumentationMode: Sendable {
    /// Install a `URLProtocol` interceptor plus two small swizzles. Every request the app
    /// makes is traced and carries `traceparent`, with no host-app changes.
    ///
    /// This is the only place the package touches the runtime, and none of it is free
    /// choice — see `MapleURLProtocol` for why the obvious approach (swizzling
    /// `URLSession`'s task-creation methods) silently misses `async` `data(for:)`.
    case automatic
    /// No swizzling. Spans and headers come from `MapleTracing.trace(_:)` /
    /// `MapleTracing.traceHeaders()`, called by the host app. For codebases where
    /// swizzling is a policy problem rather than a taste one.
    case manual
    /// No `URLSession` instrumentation of any kind.
    case off
}

public struct TracingOptions: Sendable {
    /// Public ingest key — `maple_pk_…`. Shared with replay when both run.
    public var ingestKey: String?

    /// Ingest base URL. Traces go to `{endpoint}/v1/traces`.
    public var endpoint: URL = URL(string: "https://ingest.maple.dev")!

    public var serviceName: String = "ios-app"

    /// Reported as `service.version` and `deployment.commit_sha`, matching the browser
    /// SDK. Defaults to the app's `CFBundleShortVersionString`+build.
    public var serviceVersion: String?

    /// Dual-emitted as `deployment.environment` and `deployment.environment.name` — the
    /// legacy key is pre-extracted by the Tinybird materialised views, the canonical one
    /// is the OTel semconv name.
    public var environment: String?

    /// Head sampling. The decision is recorded in the `traceparent` sampled flag, so a
    /// backend that respects it will drop the continuation too rather than producing a
    /// trace with a missing root.
    public var tracesSampleRate: Double = 1.0

    public var instrumentURLSession: URLSessionInstrumentationMode = .automatic

    /// Emit a `ui.screen` span and a `navigation` session event per
    /// `UIViewController.viewDidAppear`.
    public var instrumentViewControllers: Bool = true

    /// Hosts that may receive a `traceparent` header, as substring or regex matches
    /// against the request URL.
    ///
    /// `nil` means every host except the Maple endpoint itself — the default, and what
    /// makes "traces continue into your backend" true out of the box. Set it to your own
    /// API hosts if you would rather a third-party service (a payments API, an analytics
    /// vendor) never sees your trace ids. The header is 55 bytes and there is no CORS on
    /// native, so the cost of the broad default is disclosure, not breakage.
    public var tracePropagationTargets: [String]?

    /// Report crashes captured by MetricKit as spans carrying an `exception` event.
    ///
    /// MetricKit hands each crash over on a **later launch** — up to 24 hours later — so
    /// this answers "what is breaking in this release", not "what is breaking now". It
    /// installs no signal handler and no exception handler, so it does not compete with
    /// whatever crash reporter the host app already has.
    public var reportCrashes: Bool = true

    /// Where crash payloads wait between the launch that receives them and the export
    /// that ships them. Defaults to `<caches>/maple-tracing/`.
    public var crashDirectory: URL?

    /// Ceiling on spans held between exports. Drop-oldest past this — an app that has
    /// lost its network should not grow a queue until it is killed for memory.
    public var maxQueuedSpans: Int = 2_048

    /// How long a span may sit before export.
    ///
    /// Shorter than OTel's 5s default, for the reason the browser SDK is also at 2s: the
    /// queue is only as durable as the process, and the background flush is a best-effort
    /// catch rather than a guarantee. A few more requests buys a materially smaller loss
    /// window.
    public var exportInterval: TimeInterval = 2

    public init() {}
}
