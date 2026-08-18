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
    /// Use the **public** key. A private `maple_sk_` key authenticates too, but has no
    /// business inside an app binary, where anyone can read it back out.
    public var ingestKey: String?

    /// Ingest base URL. Defaults to the host the browser SDK uses.
    public var endpoint: URL = URL(string: "https://ingest.maple.dev")!

    public var replay = ReplayOptions()
    public var tracing = TracingOptions()

    public init() {}
}
