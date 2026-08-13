import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Everything about a spooled session that isn't a frame.
///
/// Written next to the frames so a recovery pass on the next launch can reconstruct the
/// segment without guessing: the quality tier and frame rate decide how the video is
/// encoded, and `nextChunkSeq` keeps the recovered segment from colliding with the
/// segments the crashed session already emitted.
struct SpoolManifest: Codable {
    let sessionId: String
    let startedAt: TimeInterval
    let frameRate: Int
    let quality: String
    let serviceName: String
    let environment: String?
    let userId: String

    /// Sequence number the crashed session would have used for its next segment.
    var nextChunkSeq: Int
    /// Incremented before each recovery attempt, so a session that reliably kills the
    /// recovery pass is discarded instead of retried on every launch forever.
    var recoveryAttempts: Int

    var startDate: Date { Date(timeIntervalSince1970: startedAt) }

    var replayQuality: ReplayQuality { ReplayQuality(rawValue: quality) ?? .medium }

    /// Options sufficient to re-encode the spooled frames the way the crashed session
    /// would have. Nothing else in `ReplayOptions` affects encoding.
    var encodeOptions: ReplayOptions {
        var options = ReplayOptions()
        options.frameRate = frameRate
        options.quality = replayQuality
        return options
    }
}

/// One spooled frame on disk.
struct SpooledFrame {
    let url: URL
    let sequence: Int
    let timestamp: Date
    let byteSize: Int
}

/// Mirrors the ring buffer onto disk so a hard crash doesn't take the window with it.
///
/// In `.buffered` mode the ring buffer is the entire recording until someone calls
/// `flush(trigger:)`, and a crash calls nothing. Spooling each frame as it is captured is
/// the only representation that survives `SIGKILL`, an uncatchable signal, or a watchdog
/// termination — none of which get to run cleanup code.
///
/// The in-memory buffer is kept as the fast path for ordinary flushes, but the disk copy
/// is **complete**, not a sample: every frame the buffer holds is also on disk, and
/// eviction is driven by the same capacity, so recovery yields the same window a flush
/// would have. IO cost is one small write and at most one unlink per capture — at the
/// 1 fps replay is recorded at, that is nothing.
///
/// Only redacted frames ever reach here. `CapturedFrame` is produced by
/// `RedactionPainter`, which is the first point at which a frame is allowed to be
/// retained anywhere; the unredacted `UIImage` never leaves the main thread.
///
/// Not thread-safe: `ReplayRecorder` confines all access to its capture queue.
final class FrameSpool {
    let directory: URL

    private var capacity: Int
    private let byteBudget: Int

    private var entries: [SpooledFrame] = []
    private var spooledBytes = 0
    private var nextSequence = 0
    private var manifest: SpoolManifest

    /// Set when the spool directory can't be created or written. Capture continues
    /// in memory — losing crash recovery is bad, losing the recording is worse.
    private(set) var isEnabled = true

    init(
        root: URL,
        manifest: SpoolManifest,
        capacity: Int,
        byteBudget: Int
    ) {
        self.directory = FrameSpool.sessionDirectory(root: root, sessionId: manifest.sessionId)
        self.manifest = manifest
        self.capacity = max(1, capacity)
        self.byteBudget = max(1, byteBudget)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try writeManifest()
        } catch {
            isEnabled = false
            NSLog("[MapleReplay] frame spool disabled: \(error)")
        }
    }

    // MARK: - Layout

    /// Spool directories live under a single `spool/` sibling of the session output
    /// directories, so "is there an unfinished session?" is one directory listing and
    /// never confuses a spool with a finished session's segments.
    static func spoolRoot(in root: URL) -> URL {
        root.appendingPathComponent("spool", isDirectory: true)
    }

    static func sessionDirectory(root: URL, sessionId: String) -> URL {
        spoolRoot(in: root).appendingPathComponent(sessionId, isDirectory: true)
    }

    static let manifestName = "manifest.json"
    static let frameExtension = "jpg"

    // MARK: - Capture

    /// Persist one redacted frame and evict anything now outside the window.
    func append(_ frame: CapturedFrame) {
        guard isEnabled else { return }

        let sequence = nextSequence
        nextSequence += 1
        let url = directory.appendingPathComponent(Self.frameName(sequence: sequence, timestamp: frame.timestamp))

        do {
            // Atomic: a crash mid-write leaves either the whole frame or no frame, never
            // a truncated JPEG that fails to decode during recovery.
            try frame.jpeg.write(to: url, options: .atomic)
        } catch {
            NSLog("[MapleReplay] frame spool write failed: \(error)")
            return
        }

        entries.append(
            SpooledFrame(url: url, sequence: sequence, timestamp: frame.timestamp, byteSize: frame.jpeg.count)
        )
        spooledBytes += frame.jpeg.count
        evict()
    }

    /// Evict on the ring buffer's policy — oldest first, bounded by the same frame
    /// capacity — plus a byte ceiling so an unexpectedly large frame can't blow the
    /// disk budget the frame count implies.
    private func evict() {
        while entries.count > capacity || (spooledBytes > byteBudget && entries.count > 1) {
            let oldest = entries.removeFirst()
            spooledBytes -= oldest.byteSize
            try? FileManager.default.removeItem(at: oldest.url)
        }
    }

    func resize(capacity newCapacity: Int) {
        capacity = max(1, newCapacity)
        evict()
    }

    var frameCount: Int { entries.count }
    var byteSize: Int { spooledBytes }

    // MARK: - Segment bookkeeping

    /// Called when the frames now on disk have been emitted as a segment: they are no
    /// longer at risk, and re-emitting them after a later crash would duplicate them.
    func clearFrames(nextChunkSeq: Int) {
        guard isEnabled else { return }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry.url)
        }
        entries.removeAll(keepingCapacity: true)
        spooledBytes = 0
        manifest.nextChunkSeq = nextChunkSeq
        try? writeManifest()
    }

    /// Clean shutdown: the session ended on purpose, so there is nothing to recover.
    func remove() {
        isEnabled = false
        entries.removeAll(keepingCapacity: true)
        spooledBytes = 0
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeManifest() throws {
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: directory.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    // MARK: - Frame naming
    //
    // The name carries everything recovery needs: a zero-padded sequence so a plain
    // lexicographic sort is capture order, and the capture time so the recovered segment
    // is stamped with when it actually happened rather than when it was recovered.

    static func frameName(sequence: Int, timestamp: Date) -> String {
        // `%ld`, not `%d`: epoch milliseconds do not fit in the 32 bits `%d` takes, and
        // the truncated value round-trips back to a 1970 timestamp — which then becomes
        // the recovered segment's start time and the crashed session's `end_time`.
        String(format: "%09ld-%013ld.%@", sequence, timestamp.epochMilliseconds, frameExtension)
    }

    static func parseFrameName(_ name: String) -> (sequence: Int, timestamp: Date)? {
        guard name.hasSuffix("." + frameExtension) else { return nil }
        let stem = String(name.dropLast(frameExtension.count + 1))
        let parts = stem.split(separator: "-")
        guard parts.count == 2,
              let sequence = Int(parts[0]),
              let milliseconds = Int(parts[1]) else { return nil }
        return (sequence, Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }
}

/// An unfinished session found on disk at launch.
struct SpooledSession {
    let directory: URL
    var manifest: SpoolManifest
    let frames: [SpooledFrame]

    var byteSize: Int { frames.reduce(0) { $0 + $1.byteSize } }

    /// Read a spool directory. Returns nil when there is no readable manifest — an
    /// interrupted `createDirectory`/`writeManifest` pair, or something that isn't ours.
    static func read(directory: URL) -> SpooledSession? {
        let manifestURL = directory.appendingPathComponent(FrameSpool.manifestName)
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(SpoolManifest.self, from: data) else {
            return nil
        }

        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let frames = contents.compactMap { url -> SpooledFrame? in
            guard let parsed = FrameSpool.parseFrameName(url.lastPathComponent) else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return SpooledFrame(url: url, sequence: parsed.sequence, timestamp: parsed.timestamp, byteSize: size)
        }
        .sorted { $0.sequence < $1.sequence }

        return SpooledSession(directory: directory, manifest: manifest, frames: frames)
    }

    /// Load the spooled frames back into the shape the encoder takes.
    ///
    /// Dimensions come from the JPEG headers via `CGImageSource` rather than a full
    /// decode: the encoder only needs the size up front, and decoding a 30-frame window
    /// twice at launch is wasted work on the slowest path the app has.
    func capturedFrames() -> [CapturedFrame] {
        frames.compactMap { entry in
            guard let jpeg = try? Data(contentsOf: entry.url), !jpeg.isEmpty else { return nil }
            guard let size = Self.pixelSize(of: entry.url) else { return nil }
            return CapturedFrame(jpeg: jpeg, timestamp: entry.timestamp, size: size)
        }
    }

    private static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }
}
