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
        guard let image = redact(pending, options: options),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: options.quality.frameCompression) else {
            return nil
        }
        return CapturedFrame(
            jpeg: jpeg, timestamp: pending.timestamp,
            size: CGSize(width: image.width, height: image.height), pointSize: pending.image.size
        )
    }

    /// The redacted frame at the quality tier's size, before compression.
    static func redact(_ pending: PendingFrame, options: ReplayOptions) -> CGImage? {
        let source = pending.image
        guard source.size.width.isFinite, source.size.height.isFinite,
              source.size.width >= 1, source.size.height >= 1 else { return nil }
        let targetSize = scaledSize(
            for: source.size,
            scale: options.quality.effectiveScale(forPointSize: source.size)
        )
        // Points-to-output-pixels. Derived from the rounded target rather than from the
        // requested scale, so the evening-off below can't shift the masks off their glyphs.
        // Per axis: each dimension is evened separately, so one factor for both puts
        // masks near the far edge a few pixels off their content.
        let scaleX = targetSize.width / max(source.size.width, 1)
        let scaleY = targetSize.height / max(source.size.height, 1)
        let scale = min(scaleX, scaleY)

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
        let sourceBounds = CGRect(origin: .zero, size: source.size)
        let outputBounds = CGRect(origin: .zero, size: targetSize)
        var regions: [Region] = []
        for (index, redaction) in pending.redactions.enumerated() where Self.isFinite(redaction) {
            // Trimmed to the frame before scaling: a huge but finite rect overflows to
            // infinity when scaled, and an infinite rect fills nothing.
            let rect = redaction.standardized.intersection(sourceBounds.insetBy(dx: -1, dy: -1))
            guard !rect.isNull, !rect.isEmpty else { continue }
            let scaled = rect.applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
            let fill = scaled.insetBy(dx: -padding, dy: -padding).integral
            let sensitive = pending.sensitive.contains { Self.isFinite($0) && $0.intersects(rect) }
            let kind = index < pending.kinds.count ? pending.kinds[index] : .unknown
            regions.append(Region(content: scaled.intersection(outputBounds), fill: fill, kind: kind, sensitive: sensitive))
        }

        guard let canvas = Canvas(size: targetSize) else { return nil }
        canvas.draw(source)
        switch options.maskStyle {
        case .solid:
            // Opaque fill, not a blur. A blur of large text is often reversible, and a
            // pixelation radius that is safe for one font size is not for another.
            // A flat fill has no such failure mode.
            canvas.context.setFillColor(UIColor.black.cgColor)
            for region in regions { canvas.context.fill(region.fill) }
        case .skeleton:
            paintSkeleton(regions, on: canvas, pointScale: scale)
        }

        return canvas.context.makeImage()
    }

    // MARK: - Skeleton

    /// One mask in output pixels. `fill` is the padded area that is replaced outright;
    /// `content` is the unpadded rect the placeholder shape is laid out in.
    struct Region {
        var content: CGRect
        var fill: CGRect
        var kind: MaskKind
        /// Overlaps typed input or an explicit mask: nothing inside it may tint the fill.
        var sensitive: Bool
    }

    /// Paint every region as a skeleton placeholder.
    ///
    /// Still a full replacement, like the solid style: each padded region is first filled
    /// opaque with a colour sampled from *outside* it, then a shape is drawn on top. The
    /// only colour ever taken from inside a region is the average of a non-sensitive
    /// image, and that is desaturated and blended toward the surface before use, so it
    /// keeps the image's rough tone and nothing else.
    ///
    /// Every colour is computed before anything is painted, so no region samples another
    /// region's mask, and ring pixels that fall inside any other region are skipped, so
    /// no region samples another region's content either.
    static func paintSkeleton(_ regions: [Region], on canvas: Canvas, pointScale: CGFloat) {
        let fills = regions.map(\.fill)
        let plans: [(surface: RGB, shape: Shape)] = regions.enumerated().map { index, region in
            let surface = canvas.medianColor(around: region.fill, excluding: fills, skipping: index, pointScale: pointScale)
            return (surface, shape(for: region, surface: surface, canvas: canvas, pointScale: pointScale))
        }
        let context = canvas.context
        for (region, plan) in zip(regions, plans) {
            context.setFillColor(plan.surface.cgColor)
            context.fill(region.fill)
        }
        for (region, plan) in zip(regions, plans) {
            switch plan.shape {
            case .bars(let color):
                context.setFillColor(color.cgColor)
                for bar in textBars(in: region.content, pointScale: pointScale) {
                    let radius = min(bar.height, bar.width) / 2
                    context.addPath(CGPath(roundedRect: bar, cornerWidth: radius, cornerHeight: radius, transform: nil))
                    context.fillPath()
                }
            case .block(let color):
                let rect = region.content
                guard rect.width >= 1, rect.height >= 1 else { continue }
                let radius = min(8 * pointScale, min(rect.width, rect.height) * 0.2)
                context.setFillColor(color.cgColor)
                context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
                context.fillPath()
            }
        }
    }

    enum Shape {
        case bars(RGB)
        case block(RGB)
    }

    static func shape(for region: Region, surface: RGB, canvas: Canvas, pointScale: CGFloat) -> Shape {
        let rect = region.content
        let lineLike = rect.height <= 40 * pointScale && rect.width >= rect.height * 1.2
        let isText = region.kind == .text || (region.kind == .unknown && lineLike)
        if isText { return .bars(surface.placeholderTone) }
        // A sensitive region reads only from outside itself, whatever it holds.
        guard !region.sensitive, let average = canvas.averageColor(in: rect) else {
            return .block(surface.placeholderTone)
        }
        return .block(average.muted(toward: surface))
    }

    /// Rounded bars standing in for lines of text: one per ~22 pt of height, each about
    /// half its line tall, the last one shorter when there are several.
    static func textBars(in rect: CGRect, pointScale: CGFloat) -> [CGRect] {
        guard rect.width >= 1, rect.height >= 1 else { return [] }
        let heightInPoints = rect.height / max(pointScale, 0.01)
        let lines = heightInPoints <= 34 ? 1 : max(1, Int((heightInPoints / 22).rounded()))
        let slot = rect.height / CGFloat(lines)
        let barHeight = max(min(slot * 0.5, 12 * pointScale), min(3, slot))
        return (0..<lines).map { line in
            let width = lines > 1 && line == lines - 1 ? rect.width * 0.65 : rect.width
            let y = rect.minY + slot * CGFloat(line) + (slot - barHeight) / 2
            return CGRect(x: rect.minX, y: y, width: width, height: barHeight)
        }
    }

    /// An 8-bit RGBA bitmap whose pixels are readable, with a top-left origin to match
    /// UIKit rects.
    final class Canvas {
        let context: CGContext
        let width: Int
        let height: Int

        init?(size: CGSize) {
            width = Int(size.width)
            height = Int(size.height)
            guard width > 0, height > 0,
                  let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  ) else { return nil }
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            self.context = context
        }

        func draw(_ image: UIImage) {
            UIGraphicsPushContext(context)
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height))
            UIGraphicsPopContext()
        }

        private func pixel(_ x: Int, _ y: Int) -> RGB? {
            guard x >= 0, y >= 0, x < width, y < height, let data = context.data else { return nil }
            let p = data.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
            return RGB(r: Double(p[0]) / 255, g: Double(p[1]) / 255, b: Double(p[2]) / 255)
        }

        /// Per-channel median of a band of pixels just outside `rect`, skipping pixels
        /// inside any other region. Median, so text or an icon crossing the band does not
        /// tint the result.
        func medianColor(around rect: CGRect, excluding others: [CGRect], skipping index: Int, pointScale: CGFloat) -> RGB {
            let band = max(2, Int((3 * pointScale).rounded()))
            let outer = rect.insetBy(dx: CGFloat(-band), dy: CGFloat(-band))
            let minX = Int(outer.minX), maxX = Int(outer.maxX), minY = Int(outer.minY), maxY = Int(outer.maxY)
            let perimeter = max(1, 2 * (maxX - minX + maxY - minY))
            let stride = max(1, perimeter * band / 600)
            var histograms = [[Int]](repeating: [Int](repeating: 0, count: 256), count: 3)
            var count = 0
            var step = 0
            for y in minY..<max(minY, maxY) {
                for x in minX..<max(minX, maxX) {
                    let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                    guard !rect.contains(point) else { continue }
                    step += 1
                    guard step % stride == 0 else { continue }
                    let excluded = others.indices.contains { $0 != index && others[$0].contains(point) }
                    guard !excluded, let p = pixel(x, y) else { continue }
                    histograms[0][Int(p.r * 255)] += 1
                    histograms[1][Int(p.g * 255)] += 1
                    histograms[2][Int(p.b * 255)] += 1
                    count += 1
                }
            }
            // Nothing visible around it: every neighbour is another mask or off frame.
            guard count > 0 else { return RGB(r: 0.86, g: 0.86, b: 0.88) }
            func median(_ histogram: [Int]) -> Double {
                var seen = 0
                for (value, n) in histogram.enumerated() {
                    seen += n
                    if seen * 2 >= count { return Double(value) / 255 }
                }
                return 1
            }
            return RGB(r: median(histograms[0]), g: median(histograms[1]), b: median(histograms[2]))
        }

        /// Mean colour of up to ~24x24 evenly spaced samples inside `rect`.
        func averageColor(in rect: CGRect) -> RGB? {
            let clipped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
            let columns = min(24, Int(clipped.width)), rows = min(24, Int(clipped.height))
            var sum = RGB(r: 0, g: 0, b: 0)
            var count = 0
            for row in 0..<rows {
                for column in 0..<columns {
                    let x = Int(clipped.minX + (CGFloat(column) + 0.5) * clipped.width / CGFloat(columns))
                    let y = Int(clipped.minY + (CGFloat(row) + 0.5) * clipped.height / CGFloat(rows))
                    guard let p = pixel(x, y) else { continue }
                    sum = RGB(r: sum.r + p.r, g: sum.g + p.g, b: sum.b + p.b)
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            return RGB(r: sum.r / Double(count), g: sum.g / Double(count), b: sum.b / Double(count))
        }
    }

    struct RGB: Equatable {
        var r: Double, g: Double, b: Double

        var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

        var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: 1) }

        func mixed(with other: RGB, _ amount: Double) -> RGB {
            RGB(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount)
        }

        /// A step away from the surface: darker on light surfaces, lighter on dark ones.
        var placeholderTone: RGB {
            luminance > 0.5 ? mixed(with: RGB(r: 0, g: 0, b: 0), 0.1) : mixed(with: RGB(r: 1, g: 1, b: 1), 0.16)
        }

        /// Keep a rough tone only: a third of the saturation, then half-way to the surface.
        func muted(toward surface: RGB) -> RGB {
            let grey = RGB(r: luminance, g: luminance, b: luminance)
            return grey.mixed(with: self, 0.35).mixed(with: surface, 0.5)
        }
    }

    /// Every component a real number. The scanner only emits rects clipped to the
    /// window, so anything else is broken geometry with no region to mask.
    static func isFinite(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
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
