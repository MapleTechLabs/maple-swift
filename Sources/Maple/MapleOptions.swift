import Foundation
import MapleReplay
import MapleTracing

/// Configuration for both signals.
///
/// `ingestKey` and `endpoint` are hoisted out of the two option structs because there is
/// no sensible configuration in which replay and traces go to different orgs, and having
/// them in two places is an invitation to set one and forget the other.
public struct MapleOptions: Sendable {
    /// Public ingest key — `maple_pk_…`.
    ///
    /// Leave it `nil` and it comes from `Info.plist` (`Maple.IngestKey`), which is how a
    /// build pipeline supplies it. See `resolved(against:)`.
    ///
    /// Use the **public** key. A private `maple_sk_` key authenticates too, but has no
    /// business inside an app binary, where anyone can read it back out.
    public var ingestKey: String?

    /// Ingest base URL. `nil` means `Info.plist`'s `Maple.Endpoint`, or the default host
    /// the browser SDK uses.
    public var endpoint: URL?

    /// `nil` means `Info.plist`'s `Maple.ServiceName`.
    public var serviceName: String?

    /// `nil` means `Info.plist`'s `Maple.Environment`.
    public var environment: String?

    public var replay = ReplayOptions()
    public var tracing = TracingOptions()

    public init() {}

    public static let defaultEndpoint = URL(string: "https://ingest.maple.dev")!

    /// Everything set in code, with anything left unset filled in from `Info.plist`.
    ///
    /// **Code wins.** A value written at the call site is a deliberate act by someone
    /// reading the code in front of them; the plist is the deployment default. Inverting
    /// that would make a local override impossible to spot from the source.
    ///
    /// The pipeline-facing half is documented on `MapleBundleConfiguration`.
    public func resolved(against bundle: MapleBundleConfiguration) -> MapleOptions {
        var resolved = self
        resolved.ingestKey = ingestKey ?? bundle.ingestKey
        resolved.endpoint = endpoint ?? bundle.endpoint ?? Self.defaultEndpoint
        resolved.serviceName = serviceName ?? bundle.serviceName
        resolved.environment = environment ?? bundle.environment
        if resolved.tracing.serviceVersion == nil {
            resolved.tracing.serviceVersion = bundle.serviceVersion
        }
        // Compared against the struct default rather than made optional: a sample rate is
        // a number with a meaningful default, and `1.0` is indistinguishable from "unset"
        // only because nobody sets it to exactly the default on purpose.
        if let rate = bundle.tracesSampleRate, tracing.tracesSampleRate == TracingOptions().tracesSampleRate {
            resolved.tracing.tracesSampleRate = rate
        }
        return resolved
    }
}
