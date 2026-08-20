import Foundation

/// Identity this SDK reports to the gateway.
///
/// Sent as `x-maple-sdk: <name>/<version>`, which ingest records on its span as
/// `maple.sdk`. On the web this header exists because a page cannot set `user-agent`;
/// here it exists so a mobile build is distinguishable from a browser one in the same
/// column, rather than the two being told apart by guessing from `os_name`.
public enum MapleSDK {
    public static let name = "maple-swift"
    public static let version = "0.3.2"

    /// The `x-maple-sdk` header name and value.
    public static let hintHeader = "x-maple-sdk"
    public static var hint: String { "\(name)/\(version)" }
}
