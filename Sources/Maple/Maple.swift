import Foundation
// Re-exported so `import Maple` is the only import a host app needs: `ReplayOptions`,
// `TracingOptions`, `Span` and friends come with it. An umbrella that forced three
// imports would not be much of an umbrella.
@_exported import MapleCore
@_exported import MapleReplay
@_exported import MapleTracing

/// Session replay and tracing under one call.
///
/// ```swift
/// var options = MapleOptions()
/// options.ingestKey = "maple_pk_…"
/// Maple.start(options: options, serviceName: "acme-ios", environment: "production")
/// ```
///
/// Both signals carry the same session id, which is what lets a trace resolve to the
/// recording that produced it and a recording link out to the traces it fired. Starting
/// them separately works too — the join lives in `SessionSink`, not here — but this is
/// the call that gets it right by default.
public enum Maple {
    /// Start both. Refuses without a well-formed ingest key, loudly, in each subsystem.
    @MainActor
    public static func start(
        options: MapleOptions = MapleOptions(),
        serviceName: String = "ios-app",
        environment: String? = nil,
        userId: String = ""
    ) {
        // Tracing first. The recorder publishes the session id on `start()`, and a tracer
        // that is not yet running when that happens would miss the spans of the first
        // screen — which on a cold launch is the most-watched part of any recording.
        var tracing = options.tracing
        tracing.ingestKey = options.ingestKey
        tracing.endpoint = options.endpoint
        tracing.serviceName = serviceName
        tracing.environment = environment
        MapleTracing.shared.start(options: tracing)

        var replay = options.replay
        replay.ingestKey = options.ingestKey
        replay.endpoint = options.endpoint
        MapleReplay.shared.start(
            options: replay,
            serviceName: serviceName,
            environment: environment,
            userId: userId
        )
    }

    @MainActor
    public static func stop() {
        MapleReplay.shared.stop()
        MapleTracing.shared.stop()
    }

    /// Emit whatever replay has buffered. In `.buffered` mode this is the only thing that
    /// produces a segment — wire it to your error handler.
    public static func flush(trigger: String = "manual") {
        MapleReplay.shared.flush(trigger: trigger)
        MapleTracing.shared.flush()
    }

    /// Record a product event. Appears inline in the session transcript, stamped with the
    /// trace it happened inside.
    public static func track(_ name: String, properties: [String: String] = [:]) {
        MapleReplay.shared.track(name, properties: properties)
    }

    /// Run `body` inside a span.
    @discardableResult
    public static func span<T>(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:],
        _ body: (Span?) throws -> T
    ) rethrows -> T {
        try MapleTracing.shared.span(name, kind: kind, attributes: attributes, body)
    }

    /// Async variant.
    @discardableResult
    public static func span<T>(
        _ name: String,
        kind: SpanKind = .internal,
        attributes: [String: AttributeValue] = [:],
        _ body: (Span?) async throws -> T
    ) async rethrows -> T {
        try await MapleTracing.shared.span(name, kind: kind, attributes: attributes, body)
    }

    /// Record a screen appearance — SwiftUI's equivalent of the UIKit swizzle. End the
    /// returned span in `.onDisappear` to get time-on-screen.
    @discardableResult
    public static func trackScreen(_ name: String) -> Span? {
        MapleTracing.shared.trackScreen(name)
    }
}
