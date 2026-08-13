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

    /// Longest edge of the encoded video, in pixels. Frames are downscaled to fit.
    var maxDimension: CGFloat {
        switch self {
        case .low: return 512
        case .medium: return 854
        case .high: return 1280
        }
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
    var bitrate: Int {
        switch self {
        case .low: return 100_000
        case .medium: return 300_000
        case .high: return 800_000
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

    /// Where segments are written. Defaults to `<caches>/maple-replay/<session-id>/`.
    public var outputDirectory: URL?

    public init() {}
}
