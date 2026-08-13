import Foundation
import UIKit

/// Paints redaction rects over a captured frame and compresses it.
///
/// Runs off the main thread. The output of this type is the first representation of a
/// frame that is allowed to be retained or written anywhere.
enum RedactionPainter {
    /// Slack added to every redaction rect, in output pixels.
    static let redactionPadding: CGFloat = 2

    /// Redact, downscale to the quality tier, and JPEG-compress.
    static func redactAndCompress(_ pending: PendingFrame, options: ReplayOptions) -> CapturedFrame? {
        let source = pending.image
        let targetSize = scaledSize(for: source.size, maxDimension: options.quality.maxDimension)
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
            for rect in pending.redactions {
                let scaled = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
                // Inflate before filling. A rect that exactly matches the reported bounds
                // bleeds: glyphs render marginally outside their layer's bounds, and the
                // downscale to the quality tier introduces sub-pixel offsets. Both were
                // observed as a thin line of character tops surviving above the mask.
                // Two pixels of slack costs nothing and removes the whole class of leak.
                context.fill(scaled.insetBy(dx: -Self.redactionPadding, dy: -Self.redactionPadding).integral)
            }
        }

        guard let jpeg = redacted.jpegData(compressionQuality: options.quality.frameCompression) else {
            return nil
        }
        return CapturedFrame(jpeg: jpeg, timestamp: pending.timestamp, size: targetSize)
    }

    /// Fit within `maxDimension` on the longest edge, preserving aspect ratio.
    ///
    /// Both dimensions are rounded to even numbers: H.264 chroma subsampling requires it,
    /// and AVAssetWriter silently produces a corrupt file for odd dimensions.
    static func scaledSize(for size: CGSize, maxDimension: CGFloat) -> CGSize {
        let longest = max(size.width, size.height)
        let ratio = longest > maxDimension ? maxDimension / longest : 1
        let width = (size.width * ratio).rounded()
        let height = (size.height * ratio).rounded()
        return CGSize(width: evenized(width), height: evenized(height))
    }

    private static func evenized(_ value: CGFloat) -> CGFloat {
        let integer = max(2, Int(value))
        return CGFloat(integer % 2 == 0 ? integer : integer + 1)
    }
}
