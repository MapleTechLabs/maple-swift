import Foundation

/// Turns a `CrashReport` into the span Maple's error pipeline reads.
///
/// The contract is narrow and worth stating, because half of it is invisible: a row
/// reaches `/errors` only when the span's status is `Error` **and** it carries an event
/// named `exception`. Either alone produces nothing at all.
public enum CrashSpanBuilder {
    /// Attribute namespace for everything Maple-specific, per the repo's conventions.
    public static let namespace = "maple.crash"

    public static func span(
        for report: CrashReport,
        sessionId: String?,
        sampled: Bool = true
    ) -> SpanData {
        var attributes: [String: AttributeValue] = [
            "\(namespace).source": .string("metrickit"),
        ]
        if let sessionId {
            // The join that makes this worth having: the replay recovered from the
            // crashed run carries the same id, so the error links to a recording of the
            // seconds before it.
            attributes["session.id"] = .string(sessionId)
        }
        if let signal = report.signal { attributes["\(namespace).signal"] = .string(signal) }
        if let reason = report.terminationReason {
            attributes["\(namespace).termination_reason"] = .string(reason)
        }
        if let info = report.virtualMemoryRegionInfo {
            attributes["\(namespace).virtual_memory_region_info"] = .string(info)
        }
        if !report.binaryImages.isEmpty {
            attributes["\(namespace).binary_images"] = .stringArray(report.binaryImages)
        }
        if let device = report.deviceType { attributes["device.model.identifier"] = .string(device) }

        return SpanData(
            context: SpanContext(traceId: TraceID.random(), spanId: SpanID.random(), sampled: sampled),
            parentSpanId: nil,
            name: "crash",
            kind: .internal,
            // A crash is an instant, not an interval. MetricKit reports no duration and
            // inventing one would put a fictional bar on the trace waterfall.
            startTime: report.timestamp,
            endTime: report.timestamp,
            attributes: attributes,
            status: .error(report.message),
            events: [ExceptionSemantics.event(
                type: report.exceptionType,
                message: report.message,
                stacktrace: report.stacktrace.isEmpty ? nil : report.stacktrace,
                timestamp: report.timestamp
            )],
            resourceOverrides: resourceOverrides(for: report)
        )
    }

    /// The crashed run's identity, not the running process's.
    ///
    /// MetricKit delivers a payload on the launch *after* the crash, which is routinely
    /// the launch after an update. Without this every crash fixed by a release would be
    /// filed against the release that fixed it.
    private static func resourceOverrides(for report: CrashReport) -> [String: AttributeValue] {
        var overrides: [String: AttributeValue] = [:]
        if let version = report.appVersion {
            let full = report.appBuildVersion.map { "\(version)+\($0)" } ?? version
            overrides["service.version"] = .string(full)
            overrides["deployment.commit_sha"] = .string(full)
        }
        if let osVersion = report.osVersion { overrides["os.version"] = .string(osVersion) }
        return overrides
    }
}
