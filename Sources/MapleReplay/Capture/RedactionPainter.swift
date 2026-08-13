import Foundation
import UIKit

/// Paints redaction rects over a captured frame and compresses it.
///
/// Runs off the main thread. The output of this type is the first representation of a
/// frame that is allowed to be retained or written anywhere.
enum RedactionPainter {
    /// Slack added to every redaction rect, in points. Converted to output pixels below.
    static let redactionPadding: CGFloat = 2

    /// Redact, resample to the quality tier, and JPEG-compress.
    static func redactAndCompress(_ pending: PendingFrame, options: ReplayOptions) -> CapturedFrame? {
        let source = pending.image
        let targetSize = scaledSize(
            for: source.size,
            scale: options.quality.effectiveScale(forPointSize: source.size)
        )
        // Points-to-output-pixels. Derived from the rounded target rather than from the
        // requested scale, so the evening-off below can't shift the masks off their glyphs.
        let scale = targetSize.width / max(source.size.width, 1)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let redacted = renderer.image { context in
            source.draw(in: CGRect(origin: .zero, size: targetSize))

            // Opaque fill, not a blur. A blur of large text is often reversible, and a
            // pixelation radius that is safe for one font size is not for another.
            // A flat fill has no such failure mode.
            UIColor.black.setFill()
            // Inflate before filling. A rect that exactly matches the reported bounds
            // bleeds: glyphs render marginally outside their layer's bounds, and the
            // resample to the quality tier introduces sub-pixel offsets. Both were
            // observed as a thin line of character tops surviving above the mask.
            //
            // The slack is specified in points and converted here, so a tier change can't
            // quietly shrink it — at a 2x tier a flat 2 output pixels would be one point,
            // half the slack `low` gets. The floor keeps at least two *pixels* as well,
            // which is what the sub-pixel offset needs at tiers below 1x.
            let padding = max(Self.redactionPadding, Self.redactionPadding * scale)
            for rect in pending.redactions {
                let scaled = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
                context.fill(scaled.insetBy(dx: -padding, dy: -padding).integral)
            }
        }

        guard let jpeg = redacted.jpegData(compressionQuality: options.quality.frameCompression) else {
            return nil
        }
        return CapturedFrame(jpeg: jpeg, timestamp: pending.timestamp, size: targetSize)
    }

    /// Output size in pixels for a window of `size` points at `scale` pixels per point.
    ///
    /// Both dimensions are rounded to even numbers: H.264 chroma subsampling requires it,
    /// and AVAssetWriter silently produces a corrupt file for odd dimensions. This holds
    /// for every scale, including the above-1x tiers — an odd point dimension times 2 is
    /// even, but 0.5x of an odd one is not, and neither is a fractional scale from the
    /// `maxOutputDimension` ceiling.
    static func scaledSize(for size: CGSize, scale: CGFloat) -> CGSize {
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        return CGSize(width: evenized(width), height: evenized(height))
    }

    private static func evenized(_ value: CGFloat) -> CGFloat {
        let integer = max(2, Int(value))
        return CGFloat(integer % 2 == 0 ? integer : integer + 1)
    }
}
