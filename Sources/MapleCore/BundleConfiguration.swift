import Foundation

/// Configuration read from the app's `Info.plist`.
///
/// This is the seam a build pipeline configures. `ProcessInfo.environment` is not: it is
/// populated only when the app is launched by Xcode or `simctl`, so an SDK configured
/// that way works on a developer's machine and is unconfigured in TestFlight — which
/// fails silently, because ingest answers a missing key with 401 and every transport here
/// swallows it by design.
///
/// The values are expected to arrive as build settings, substituted by Xcode at build
/// time:
///
/// ```
/// <key>Maple</key>
/// <dict>
///     <key>IngestKey</key>
///     <string>$(MAPLE_INGEST_KEY)</string>
/// </dict>
/// ```
///
/// so a pipeline supplies them the same way it supplies a bundle id or a version:
/// `xcodebuild MAPLE_INGEST_KEY=…`, an Xcode Cloud environment variable, an `.xcconfig`,
/// or Fastlane's `xcargs`.
public struct MapleBundleConfiguration: Sendable {
    public var ingestKey: String?
    public var endpoint: URL?
    public var environment: String?
    public var serviceName: String?
    public var serviceVersion: String?
    public var tracesSampleRate: Double?

    public init() {}

    /// The dictionary key everything lives under. Namespaced rather than flat so a host
    /// app's own `Endpoint` key cannot collide with ours.
    public static let dictionaryKey = "Maple"

    public static func read(from bundle: Bundle = .main) -> MapleBundleConfiguration {
        var configuration = MapleBundleConfiguration()
        let values = readValues(from: bundle)
        guard !values.isEmpty else { return configuration }

        configuration.ingestKey = string(values["IngestKey"], key: "IngestKey")
        configuration.environment = string(values["Environment"], key: "Environment")
        configuration.serviceName = string(values["ServiceName"], key: "ServiceName")
        configuration.serviceVersion = string(values["ServiceVersion"], key: "ServiceVersion")

        if let raw = string(values["Endpoint"], key: "Endpoint") {
            if let url = URL(string: raw), url.scheme != nil {
                configuration.endpoint = url
            } else {
                MapleLog.notice("Maple", "Info.plist Maple.Endpoint is not a valid URL (\(raw)); using the default endpoint")
            }
        }

        // Tolerates both `<real>` and `<string>`: a build setting substituted into a
        // plist is always a string, and hand-written plists tend to use a number.
        if let number = values["TracesSampleRate"] as? NSNumber {
            configuration.tracesSampleRate = number.doubleValue
        } else if let raw = string(values["TracesSampleRate"], key: "TracesSampleRate") {
            if let value = Double(raw) {
                configuration.tracesSampleRate = value
            } else {
                MapleLog.notice("Maple", "Info.plist Maple.TracesSampleRate is not a number (\(raw)); ignoring")
            }
        }

        return configuration
    }

    /// Settings under either shape, normalised to one dictionary.
    ///
    /// Two shapes because a build pipeline should not have to add an `Info.plist` file to
    /// configure this. Xcode's generated plist (`GENERATE_INFOPLIST_FILE = YES`, the
    /// default for a new app) can only be extended with **flat** keys, via
    /// `INFOPLIST_KEY_<name>` build settings — so a nested-only design would force every
    /// adopter to hand-manage a plist just to set one string.
    ///
    /// The nested form wins where both are present: it is the explicit one.
    private static func readValues(from bundle: Bundle) -> [String: Any] {
        var values: [String: Any] = [:]
        for field in ["IngestKey", "Endpoint", "Environment", "ServiceName", "ServiceVersion", "TracesSampleRate"] {
            if let flat = bundle.object(forInfoDictionaryKey: "Maple\(field)") {
                values[field] = flat
            }
        }
        if let nested = bundle.object(forInfoDictionaryKey: dictionaryKey) as? [String: Any] {
            values.merge(nested) { _, explicit in explicit }
        }
        return values
    }

    /// Reads one value, rejecting the two shapes that mean "the pipeline did not set this".
    ///
    /// An `$(MAPLE_INGEST_KEY)` that survives into the built plist means no such build
    /// setting was defined — Xcode leaves the token verbatim. Treating it as a key would
    /// send every request with a literal `$(…)` bearer token and earn a 401 that nothing
    /// surfaces. Better to say so once, here, where a developer is looking.
    private static func string(_ value: Any?, key: String) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if raw.contains("$(") || raw.hasPrefix("${") {
            MapleLog.notice(
                "Maple",
                "Info.plist Maple.\(key) is still the unsubstituted build setting \(raw) — define it in your build settings, .xcconfig, or CI environment."
            )
            return nil
        }
        return raw
    }
}
