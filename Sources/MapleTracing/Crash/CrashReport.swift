import Foundation

/// One frame of a crashed thread's stack.
///
/// Unsymbolicated, which is all MetricKit has: the app's own symbols live in a dSYM that
/// never leaves the build machine. `binaryUUID` and `offset` are the pair a symbol server
/// would need to recover a function name later, so both are carried even though neither
/// is readable on its own.
public struct CrashFrame: Equatable, Sendable {
    public let binaryName: String
    public let binaryUUID: String
    public let address: UInt64
    /// Offset into the binary's text segment. MetricKit reports this directly, so unlike
    /// a raw `.crash` file there is no load-address arithmetic and no ASLR slide to undo.
    public let offset: UInt64

    /// Apple's crash-report frame layout, which is what an iOS developer reads all day.
    ///
    /// The offset is rendered in **hex** rather than Apple's decimal, and that is load
    /// bearing: Maple's fingerprint redacts `0x…` runs from a frame before hashing it, so
    /// a hex offset disappears and leaves `index binaryName +`. A decimal offset would
    /// survive redaction, and since an offset shifts with any code change, every rebuild
    /// would re-split every issue. Hex buys grouping that is stable across releases.
    /// The frame index is not part of this — `CrashReport.stacktrace` prepends it, since
    /// only the full stack knows a frame's position.
    public var rendered: String {
        "\(binaryName)   0x\(String(address, radix: 16))   +0x\(String(offset, radix: 16))"
    }
}

/// A crash, decoupled from `MetricKit`.
///
/// The whole pipeline downstream of the parser works on this type, so every part of it
/// can be tested from a fixture — `MXCrashDiagnostic` cannot be constructed in a test,
/// and its `callStackTree` only exposes JSON anyway.
public struct CrashReport: Equatable, Sendable {
    public let exceptionType: String
    public let message: String
    public let frames: [CrashFrame]
    public let signal: String?
    public let terminationReason: String?
    public let virtualMemoryRegionInfo: String?
    /// The version that crashed, which is not necessarily the version now running.
    public let appVersion: String?
    public let appBuildVersion: String?
    public let osVersion: String?
    public let deviceType: String?
    public let timestamp: Date

    /// Innermost frame first, matching every crash report Apple has ever printed.
    public var stacktrace: String {
        frames.enumerated()
            .map { index, frame in "\(index)   \(frame.rendered)" }
            .joined(separator: "\n")
    }

    /// `binaryName=UUID` pairs for the binaries in this stack, deduplicated.
    ///
    /// The rendered stack cannot carry the UUIDs (redaction would strip them, and they
    /// would swamp the line), but symbolicating later needs them. Kept as one attribute
    /// so a future symbol server has everything it needs on the span itself.
    public var binaryImages: [String] {
        var seen = Set<String>()
        return frames.compactMap { frame in
            guard !frame.binaryUUID.isEmpty, seen.insert(frame.binaryName).inserted else { return nil }
            return "\(frame.binaryName)=\(frame.binaryUUID)"
        }
    }
}
