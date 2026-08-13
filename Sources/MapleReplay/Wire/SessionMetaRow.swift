import Foundation
import UIKit

/// Builds the `/v1/sessionReplays/meta` NDJSON row.
///
/// Field names and semantics are taken verbatim from
/// `packages/browser-session/src/meta-row.ts` so a mobile session is the same shape as a
/// web one. Two constraints carried over from there matter and are easy to get wrong:
///
///  1. The backing table is a **ReplacingMergeTree keyed on Version** that replaces the
///     whole row, not a merge. Every field must therefore be present on the *base*
///     (`active`) row — anything emitted only on the `ended` row is missing for every
///     session that dies without a clean shutdown, which on mobile is most of them.
///  2. `referrer_host` and `country` are derived at the gateway on purpose, so one
///     normalisation covers every SDK version in the wild. Do not send them.
///
/// Milestone 1 writes this to `meta.ndjson` instead of POSTing it. Note for milestone 2:
/// this row is the **billed** unit — blobs are not metered. An SDK that uploads chunks
/// without ever posting a meta row bills nothing and its sessions never appear in the UI.
public struct SessionMetaRow {
    public enum Status: String { case active, ended }

    let sessionId: String
    let startedAt: Date
    let status: Status
    let version: Int
    let serviceName: String
    let environment: String?
    let userId: String
    let recorded: Bool

    func json(now: Date = Date()) -> [String: Any] {
        var resourceAttributes: [String: String] = [
            "maple.session.recorded": recorded ? "true" : "false",
        ]
        if let environment {
            // Dual-emit: the legacy key is pre-extracted by the Tinybird MVs, the
            // canonical one is the OTel semconv name.
            resourceAttributes["deployment.environment"] = environment
            resourceAttributes["deployment.environment.name"] = environment
        }

        let device = UIDevice.current

        var row: [String: Any] = [
            "session_id": sessionId,
            "start_time": Self.clickHouseDateTime(startedAt),
            "status": status.rawValue,
            "version": version,
            "user_id": userId,
            "service_name": serviceName,
            "resource_attributes": resourceAttributes,

            // These columns are LowCardinality and capped at the gateway. Send stable,
            // low-cardinality values — never a full OS build string.
            "os_name": device.systemName,
            "device_type": Self.deviceType(),
            // There is no browser. Leaving it empty rather than inventing a value keeps
            // the web analytics facets honest.
            "browser_name": "",
            "user_agent": Self.userAgent(),

            // Web-shaped columns with no mobile analogue. Sent empty rather than
            // repurposed, so a URL facet never shows a screen name pretending to be a URL.
            "url_initial": "",
            "referrer": "",
            "host": "",
            "entry_path": "",
            "exit_path": "",
            "utm_source": "", "utm_medium": "", "utm_campaign": "",
            "utm_term": "", "utm_content": "",

            "visitor_id": "",
            "visitor_is_new": 0,
            "user_email": "",
            "user_name": "",
            "group_id": "",
            "group_name": "",
            "user_traits": [String: String](),
            "language": Locale.preferredLanguages.first ?? "",
            "last_activity_at": Self.clickHouseDateTime(now),
            "click_count": 0,
            "page_views": 0,
            "error_count": 0,
        ]

        if status == .ended {
            row["end_time"] = Self.clickHouseDateTime(now)
            row["duration_ms"] = max(0, Int(now.timeIntervalSince(startedAt) * 1000))
            row["trace_ids"] = [String]()
        }
        return row
    }

    /// One NDJSON line, newline-terminated — the exact body of the meta POST.
    func ndjson(now: Date = Date()) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: json(now: now), options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// ClickHouse `DateTime64(3)` literal: `YYYY-MM-DD HH:MM:SS.mmm`, always UTC.
    static func clickHouseDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: date)
    }

    static func deviceType() -> String {
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return "mobile"
        case .pad: return "tablet"
        case .tv: return "tv"
        case .mac: return "desktop"
        default: return "unknown"
        }
    }

    /// A short, low-cardinality descriptor. Deliberately not the full model identifier —
    /// this column is LowCardinality and one entry per device revision would defeat it.
    static func userAgent() -> String {
        let device = UIDevice.current
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        return "\(device.systemName)/\(major) (\(deviceType()))"
    }
}
