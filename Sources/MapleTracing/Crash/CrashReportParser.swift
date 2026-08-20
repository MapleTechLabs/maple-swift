import Foundation

/// Turns `MXDiagnosticPayload.jsonRepresentation()` into `CrashReport`s.
///
/// Parsing the JSON rather than reading `MXCrashDiagnostic`'s typed properties is a
/// testability decision, and it costs nothing: `callStackTree` exposes *only* JSON, so
/// the stack has to be parsed either way, and `MXCrashDiagnostic` has no public
/// initialiser, so a typed path could never be exercised by a unit test.
public enum CrashReportParser {
    /// Mach exception types. The JSON carries the raw integer.
    private static let machExceptions: [Int: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC",
        4: "EXC_EMULATION", 5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT",
        7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL", 9: "EXC_RPC_ALERT",
        10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
    ]

    private static let signals: [Int: String] = [
        4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 8: "SIGFPE",
        9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 13: "SIGPIPE", 15: "SIGTERM",
    ]

    /// Maximum frames kept per crash.
    ///
    /// The fingerprint only reads the top 3, and a deep recursion crash can carry
    /// hundreds of thousands — the whole span has to fit in a request that is also
    /// carrying everything else queued.
    static let maxFrames = 64

    public static func reports(fromPayload data: Data, receivedAt: Date = Date()) -> [CrashReport] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let diagnostics = root["crashDiagnostics"] as? [[String: Any]]
        else { return [] }

        let timestamp = date(root["timeStampEnd"]) ?? receivedAt
        return diagnostics.compactMap { report(from: $0, timestamp: timestamp) }
    }

    private static func report(from diagnostic: [String: Any], timestamp: Date) -> CrashReport? {
        let meta = diagnostic["diagnosticMetaData"] as? [String: Any] ?? [:]

        let signalName = (meta["signal"] as? Int).flatMap { signals[$0] }
        let exceptionType = (meta["exceptionType"] as? Int).flatMap { machExceptions[$0] }
            ?? signalName
            ?? "Crash"

        let frames = self.frames(from: diagnostic["callStackTree"] as? [String: Any])

        // Every crash of one type would otherwise share a message, and the message is
        // what the fingerprint falls back to when no frame matches. The signal and the
        // termination reason are the only cheap discriminators MetricKit offers.
        var message = exceptionType
        if let signalName, signalName != exceptionType { message += " (\(signalName))" }
        if let reason = meta["terminationReason"] as? String, !reason.isEmpty {
            message += ": \(reason)"
        }

        return CrashReport(
            exceptionType: exceptionType,
            message: message,
            frames: frames,
            signal: signalName,
            terminationReason: meta["terminationReason"] as? String,
            virtualMemoryRegionInfo: meta["virtualMemoryRegionInfo"] as? String,
            appVersion: meta["appVersion"] as? String,
            appBuildVersion: meta["appBuildVersion"] as? String,
            osVersion: meta["osVersion"] as? String,
            deviceType: meta["deviceType"] as? String,
            timestamp: timestamp
        )
    }

    /// Flatten the call-stack tree, innermost frame first.
    ///
    /// `callStackRootFrames` is the **base** of the stack — `start`, `main` — with
    /// `subFrames` descending toward the crash site, so the tree arrives in exactly the
    /// opposite order to the one a crash report prints and a fingerprint wants. Reading
    /// it root-first would hash `main` for every crash in the app and collapse every
    /// issue into one.
    private static func frames(from tree: [String: Any]?) -> [CrashFrame] {
        guard
            let stacks = tree?["callStacks"] as? [[String: Any]],
            let stack = stacks.first(where: { $0["threadAttributed"] as? Bool == true }) ?? stacks.first,
            let roots = stack["callStackRootFrames"] as? [[String: Any]]
        else { return [] }

        var chain: [CrashFrame] = []
        var node = roots.first
        while let current = node, chain.count < maxFrames {
            if let frame = frame(from: current) { chain.append(frame) }
            node = (current["subFrames"] as? [[String: Any]])?.first
        }
        return chain.reversed()
    }

    private static func frame(from node: [String: Any]) -> CrashFrame? {
        guard let binaryName = node["binaryName"] as? String else { return nil }
        return CrashFrame(
            binaryName: binaryName,
            binaryUUID: node["binaryUUID"] as? String ?? "",
            address: uint(node["address"]) ?? 0,
            offset: uint(node["offsetIntoBinaryTextSegment"]) ?? 0
        )
    }

    private static func uint(_ value: Any?) -> UInt64? {
        if let number = value as? UInt64 { return number }
        if let number = value as? Int { return number >= 0 ? UInt64(number) : nil }
        if let number = value as? NSNumber { return number.uint64Value }
        return nil
    }

    /// MetricKit stamps dates as `2026-08-20 12:00:00 +0000`.
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        return formatter.date(from: string)
    }
}
