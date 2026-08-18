import Foundation
import MapleCore
import UIKit

/// OTel resource attributes for this app.
///
/// Fixed for the tracer's lifetime, which is exactly why `session.id` is **not** here:
/// iOS rotates the session on every foreground transition, and a resource-level id would
/// attribute every post-rotation span to a session that has already reported itself
/// ended. The tracer stamps the live id per span instead — the same call the browser
/// SDK's `TraceIdCollector` makes, and for the same reason.
enum ResourceAttributes {
    static func build(options: TracingOptions) -> [String: AttributeValue] {
        var attributes: [String: AttributeValue] = [
            "service.name": .string(options.serviceName),
            // Counterpart to the browser SDK's "browser". Lets one query separate mobile
            // traffic from web without inferring it from `os.name`.
            "maple.sdk.type": .string("ios"),
            "telemetry.sdk.name": .string(MapleSDK.name),
            "telemetry.sdk.version": .string(MapleSDK.version),
            "telemetry.sdk.language": .string("swift"),
        ]

        if let version = options.serviceVersion ?? bundleVersion() {
            attributes["service.version"] = .string(version)
            attributes["deployment.commit_sha"] = .string(version)
        }

        if let environment = options.environment {
            // Dual-emit: the legacy key is pre-extracted by the Tinybird MVs, the
            // canonical one is the OTel semconv name. Keep both until the MVs coalesce.
            attributes["deployment.environment"] = .string(environment)
            attributes["deployment.environment.name"] = .string(environment)
        }

        let device = UIDevice.current
        attributes["os.name"] = .string(device.systemName)
        attributes["os.version"] = .string(device.systemVersion)
        attributes["device.manufacturer"] = .string("Apple")
        // `utsname.machine` ("iPhone17,1"), not `device.model` ("iPhone") — the marketing
        // name is the same string for every phone Apple has ever shipped.
        attributes["device.model.identifier"] = .string(hardwareIdentifier())
        if let bundleId = Bundle.main.bundleIdentifier {
            attributes["service.namespace"] = .string(bundleId)
        }

        return attributes
    }

    private static func bundleVersion() -> String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String else { return short }
        return "\(short)+\(build)"
    }

    private static func hardwareIdentifier() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            guard let base = bytes.baseAddress else { return "unknown" }
            return String(cString: base)
        }
    }
}
