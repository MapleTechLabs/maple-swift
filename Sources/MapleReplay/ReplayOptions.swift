import Foundation
import UIKit

/// How captured frames are turned into segments.
///
/// Both policies are driven off the same ring buffer — `.continuous` is simply
/// "flush on every boundary", `.buffered` is "flush only when asked". Keeping one
/// buffer means error-triggered capture is not a special case bolted on later.
public enum FlushPolicy: Equatable, Sendable {
    /// Emit a segment every `segmentDuration` seconds for the whole session.
    case continuous(segmentDuration: TimeInterval)
    /// Hold the last `window` seconds in memory and emit only on `flush(trigger:)`.
    case buffered(window: TimeInterval)

    /// Seconds of video the ring buffer must be able to hold for this policy.
    var retainedSeconds: TimeInterval {
        switch self {
        case .continuous(let duration): return duration
        case .buffered(let window): return window
        }
    }

    public static let defaultContinuous = FlushPolicy.continuous(segmentDuration: 5)
    public static let defaultBuffered = FlushPolicy.buffered(window: 30)
}

/// Output resolution / compression tier. Mirrors Sentry's three-tier model.
public enum ReplayQuality: String, Sendable, CaseIterable {
    case low, medium, high

    /// Output pixels per point of window.
    ///
    /// Point-relative, not an absolute pixel cap. A phone window is ~400×875 pt, so any
    /// cap above ~875 px never binds and every tier above `low` collapses onto the native
    /// size — measured, `medium` (854 px) and `high` (1280 px) landed within 4% of each
    /// other and the setting was a no-op. Expressed as a multiple of the screen's own
    /// geometry, the three tiers differ by a factor of two per step on any device.
    ///
    /// `high` is deliberately above 1×: the tier only means anything if it can resolve
    /// detail the point grid can't. Capture scale follows this value, so a 2× tier really
    /// rasterises at 2×. Measured on a 402×874 pt window, that costs ~1 ms and a 5.4 MB
    /// transient bitmap per frame over 1× — at 1 fps, nothing.
    var renderScale: CGFloat {
        switch self {
        case .low: return 0.5
        case .medium: return 1
        case .high: return 2
        }
    }

    /// Hard ceiling on the longest output edge, in pixels.
    ///
    /// This is a memory bound, not the tier dial — `renderScale` is the dial. It exists
    /// for iPad, where a 1366 pt window at the `high` tier would otherwise rasterise a
    /// 2732 px frame (30 MB of transient ARGB). On a phone it never binds.
    static let maxOutputDimension: CGFloat = 2_048

    /// Pixels per point actually used for a window of `pointSize`, after the ceiling.
    func effectiveScale(forPointSize pointSize: CGSize) -> CGFloat {
        let longest = max(pointSize.width, pointSize.height)
        guard longest > 0 else { return renderScale }
        return min(renderScale, Self.maxOutputDimension / longest)
    }

    /// JPEG quality used for frames held in the ring buffer.
    var frameCompression: CGFloat {
        switch self {
        case .low: return 0.4
        case .medium: return 0.6
        case .high: return 0.8
        }
    }

    /// Target H.264 bitrate for the encoded segment.
    ///
    /// Roughly proportional to the tier's pixel count, so the ceiling stays equally slack
    /// at every tier. On near-static screens the encoder lands far below it; the number
    /// only matters when the screen is busy.
    var bitrate: Int {
        switch self {
        case .low: return 100_000
        case .medium: return 400_000
        case .high: return 1_600_000
        }
    }
}

public struct ReplayOptions: Sendable {
    /// Frames captured per second. 1 is the default across every mobile replay SDK
    /// worth copying — replay is for understanding flow, not animation.
    public var frameRate: Int = 1

    public var quality: ReplayQuality = .medium

    public var flushPolicy: FlushPolicy = .defaultContinuous

    // MARK: Masking
    //
    // Every masking default is ON. A missed mask writes PII to storage permanently;
    // an over-broad mask is only ugly. The asymmetry is total, so the defaults are not
    // a matter of taste.

    /// Redact every view that renders text.
    public var maskAllText: Bool = true

    /// Redact every view that renders an image.
    public var maskAllImages: Bool = true

    /// Views of these classes are always redacted, on top of the rules above.
    public var maskedViewClasses: [AnyClass] = []

    /// Views of these classes are never redacted. The only way to opt out.
    public var unmaskedViewClasses: [AnyClass] = []

    /// Draw the redaction rects on screen instead of only into captured frames.
    /// Debug affordance — see `MaskingPreviewView`.
    public var showMaskingPreview: Bool = false

    // MARK: Transport

    /// Public ingest key — `maple_pk_…`.
    ///
    /// Required: `start()` refuses to record without a well-formed one rather than
    /// spending a user's battery on a session it can never deliver. See
    /// `IngestKeyProblem`.
    ///
    /// Use the **public** key. A private `maple_sk_` key authenticates too, but has no
    /// business inside an app binary, where anyone can read it back out.
    public var ingestKey: String?

    /// Ingest base URL. Defaults to the host the browser SDK uses.
    public var endpoint: URL = URL(string: "https://ingest.maple.dev")!

    /// Also write each segment to `outputDirectory` — `segment-NNN.json.gz`, the
    /// inspectable MP4 beside it, and `meta.ndjson`.
    ///
    /// Off by default: upload needs none of it. It stays because reading the exact bytes
    /// that went over the wire, and watching the video to check redaction, is how this
    /// gets debugged.
    public var writeSegmentsToDisk: Bool = false

    /// Where segments are written when `writeSegmentsToDisk` is on, and the parent of the
    /// crash-recovery spool. Defaults to `<caches>/maple-replay/`.
    public var outputDirectory: URL?

    // MARK: Crash recovery

    /// Spool each captured frame to disk so the in-flight window survives a crash, and
    /// recover any unfinished session at the next `start()`.
    ///
    /// On by default. In `.buffered` mode the buffer *is* the recording until something
    /// calls `flush(trigger:)`, and a crash calls nothing — without this, the 30 seconds
    /// before a crash, the recording most worth having, is the one recording that is
    /// guaranteed to be lost.
    public var crashRecovery: Bool = true

    /// Ceiling on one session's spooled frames. Eviction normally happens on the ring
    /// buffer's frame capacity; this bounds the pathological case where frames are far
    /// larger than the tier suggests.
    public var maxSpoolBytes: Int = 16 * 1024 * 1024

    /// Ceiling on *all* spool directories together, applied at launch before recovery.
    ///
    /// The bound that matters: a crash loop leaves a fresh spool on every launch, so a
    /// per-session limit alone would let a device fill up one crash at a time.
    public var maxTotalSpoolBytes: Int = 48 * 1024 * 1024

    public init() {}
}
