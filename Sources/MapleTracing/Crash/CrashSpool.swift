import Foundation
import MapleCore

/// Payloads waiting to become spans, on disk.
///
/// Exists because of one MetricKit property: a diagnostic payload is delivered **once**.
/// It arrives shortly after launch, which is routinely before `start()` has run and
/// always before the exporter has a network path, and if it is dropped there is no second
/// delivery. Writing it down first costs a few kilobytes and makes the rest of the
/// pipeline free to fail.
struct CrashSpool {
    /// Ceiling on spooled payloads.
    ///
    /// An app crashing on launch generates one per launch, and the whole point of the
    /// spool is that nothing has successfully exported yet — without a cap it is an
    /// unbounded write loop on a user's device. Oldest are dropped.
    static let maxPayloads = 8

    let directory: URL

    private var spoolDirectory: URL { directory.appendingPathComponent("crashes", isDirectory: true) }

    func write(_ payload: Data) {
        guard !payload.isEmpty else { return }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)

        // Nanoseconds so the name sorts by arrival even when two land in one millisecond.
        let name = "\(UInt64(Date().timeIntervalSince1970 * 1_000_000_000)).json"
        do {
            try payload.write(to: spoolDirectory.appendingPathComponent(name), options: .atomic)
        } catch {
            MapleLog.warnOnce("MapleTracing", "crash spool", error)
            return
        }
        trim()
    }

    /// Read and remove everything spooled, oldest first.
    func drain() -> [Data] {
        let files = spooledFiles()
        return files.compactMap { url in
            defer { try? FileManager.default.removeItem(at: url) }
            return try? Data(contentsOf: url)
        }
    }

    private func spooledFiles() -> [URL] {
        let contents = try? FileManager.default.contentsOfDirectory(
            at: spoolDirectory,
            includingPropertiesForKeys: nil
        )
        return (contents ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func trim() {
        let files = spooledFiles()
        guard files.count > Self.maxPayloads else { return }
        for url in files.prefix(files.count - Self.maxPayloads) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
