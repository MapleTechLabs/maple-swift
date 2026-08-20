import Foundation
import MapleCore
#if canImport(MetricKit)
import MetricKit
#endif

/// Reports crashes as OTLP spans, sourced from MetricKit.
///
/// MetricKit rather than `NSSetUncaughtExceptionHandler` plus signal handlers: this is an
/// SDK that ships inside other people's apps, where installing a signal handler means
/// running async-signal-unsafe code in a process that is already dying, and fighting
/// whatever crash reporter the app already has for the same slot. The OS captures the
/// crash instead, and hands it over on a later launch.
///
/// The cost is latency — a payload can arrive up to 24 hours after the crash — so this is
/// a "what is broken in this release" signal, not a live one.
final class CrashReporter: NSObject, @unchecked Sendable {
    private let spool: CrashSpool
    private let emit: (SpanData) -> Void
    private let sessionId: String?

    init(directory: URL, sessionId: String?, emit: @escaping (SpanData) -> Void) {
        self.spool = CrashSpool(directory: directory)
        self.emit = emit
        self.sessionId = sessionId
        super.init()
    }

    func start() {
        // Anything left by a previous launch goes first: a payload can be spooled by a
        // run that never got the chance to export it.
        drain()
        #if canImport(MetricKit) && !targetEnvironment(simulator)
        MXMetricManager.shared.add(self)
        #endif
    }

    func stop() {
        #if canImport(MetricKit) && !targetEnvironment(simulator)
        MXMetricManager.shared.remove(self)
        #endif
    }

    /// Convert everything spooled into spans and hand them to the processor.
    ///
    /// Spooled payloads are removed as they are read, not after a successful upload. The
    /// exporter is best-effort and never retries — the same posture as every other signal
    /// in this SDK — so there is no delivery result to wait for, and keeping them would
    /// re-report the same crash on every launch forever.
    func drain() {
        for payload in spool.drain() {
            for report in CrashReportParser.reports(fromPayload: payload) {
                emit(CrashSpanBuilder.span(for: report, sessionId: sessionId))
            }
        }
    }

    /// Test seam: the path a `MXDiagnosticPayload` takes once it is JSON.
    func ingest(payload: Data) {
        spool.write(payload)
        drain()
    }
}

#if canImport(MetricKit) && !targetEnvironment(simulator)
extension CrashReporter: MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metrics, not diagnostics. Nothing to do with crashes.
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Spool first, convert second. MetricKit delivers each payload exactly once, so a
        // payload dropped because the tracer had not started yet is gone for good.
        for payload in payloads where !payload.crashDiagnostics.isNilOrEmpty {
            spool.write(payload.jsonRepresentation())
        }
        drain()
    }
}

private extension Optional where Wrapped: Collection {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}
#endif
