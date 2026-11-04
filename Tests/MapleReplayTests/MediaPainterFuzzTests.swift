import UIKit
import XCTest
@testable import MapleReplay

/// `RedactionPainter` with hostile sizes and rects. The painter is the last step before
/// a frame may be retained, so whatever the scanner hands it, a finite rect over the
/// image must be fully replaced (black in the solid style) and nothing may crash.
final class MediaPainterFuzzTests: XCTestCase {
    func testScaledSizeIsEvenAndAtLeastTwoForAnyInput() {
        for seed in PrivacyFuzzConfig.seeds(default: 300) {
            var rng = PrivacyFuzzRNG(seed: seed)
            let hostile: [CGFloat] = [0, -1, 0.4, 1, 1.5, 3, 2047, 2048, 2049, 1e9, .nan, .infinity, -.infinity]
            let size = CGSize(
                width: rng.chance(0.3) ? rng.pick(hostile) : rng.cgFloat(0...4096),
                height: rng.chance(0.3) ? rng.pick(hostile) : rng.cgFloat(0...4096)
            )
            let scale = rng.chance(0.3) ? rng.pick(hostile) : rng.cgFloat(0...3)
            // Only finite products are representable as Int; the painter guards its own
            // inputs, so non-finite ones are a caller contract, checked separately below.
            guard (size.width * scale).isFinite, (size.height * scale).isFinite,
                  abs(size.width * scale) < 1e15, abs(size.height * scale) < 1e15 else { continue }
            let out = RedactionPainter.scaledSize(for: size, scale: scale)
            for dimension in [out.width, out.height] {
                XCTAssertGreaterThanOrEqual(dimension, 2, "\(PrivacyFuzzConfig.describe(seed)) \(size) x\(scale) -> \(out)")
                XCTAssertEqual(Int(dimension) % 2, 0, "\(PrivacyFuzzConfig.describe(seed)) \(size) x\(scale) -> \(out)")
            }
        }
    }

    func testEveryFiniteRectOverTheImageComesOutBlack() throws {
        var checkedRects = 0
        for seed in PrivacyFuzzConfig.seeds(default: 40, slowDivisor: 4) {
            var rng = PrivacyFuzzRNG(seed: seed)
            let size = randomSourceSize(&rng)
            var options = ReplayOptions()
            options.quality = rng.pick(ReplayQuality.allCases)
            options.maskStyle = .solid
            let rects = (0..<rng.int(0...12)).map { _ in randomRect(&rng, in: size) }
            let pending = PendingFrame(
                image: PrivacyFuzzPalette.solidImage(.white, size: size), redactions: rects, timestamp: Date()
            )
            let context = "\(PrivacyFuzzConfig.describe(seed)) source=\(size) quality=\(options.quality) rects=\(rects)"

            let frame = try XCTUnwrap(RedactionPainter.redactAndCompress(pending, options: options), context)
            XCTAssertGreaterThanOrEqual(frame.size.width, 2, context)
            XCTAssertGreaterThanOrEqual(frame.size.height, 2, context)
            XCTAssertEqual(Int(frame.size.width) % 2, 0, context)
            XCTAssertEqual(Int(frame.size.height) % 2, 0, context)
            XCTAssertLessThanOrEqual(max(frame.size.width, frame.size.height), ReplayQuality.maxOutputDimension + 2, context)
            let bitmap = try XCTUnwrap(PrivacyFuzzBitmap(jpeg: frame.jpeg), context)
            XCTAssertEqual(CGSize(width: bitmap.width, height: bitmap.height), frame.size, context)

            // Per axis: the source is drawn stretched to the even output size, so a rect's
            // content lands at these scales even where the two axes rounded differently.
            let scaleX = frame.size.width / size.width
            let scaleY = frame.size.height / size.height
            for rect in rects {
                let values = [rect.origin.x, rect.origin.y, rect.width, rect.height]
                guard values.allSatisfy(\.isFinite) else { continue }
                let target = rect.standardized
                    .applying(CGAffineTransform(scaleX: scaleX, y: scaleY))
                    .intersection(CGRect(origin: .zero, size: frame.size))
                    .insetBy(dx: 0.5, dy: 0.5)
                guard !target.isNull, target.width > 0, target.height > 0 else { continue }
                checkedRects += 1
                for (x, y) in samplePoints(in: target) {
                    let p = bitmap.pixel(x, y)
                    if max(p.r, p.g, p.b) > 100 {
                        XCTFail("PRIVACY LEAK (painter): pixel (\(x),\(y)) = \(p) inside redaction \(rect) is not black. \(context)")
                        break
                    }
                }
            }
        }
        XCTAssertGreaterThan(checkedRects, 0, "no rect ever intersected an image: nothing was checked")
    }

    /// Minimized from seed 0x00c0ffee5eed0001. The painter maps rects with the width's
    /// scale only, but the height rounds to even on its own. On a 393 pt wide phone
    /// (iPhone 15, 16) at `low` that pushes masks near the bottom ~3 px down, past the 2 px
    /// padding, and the top row of the masked content survives.
    func testMasksStayAlignedOnA393PointWideWindowAtLowQuality() throws {
        let size = CGSize(width: 393, height: 852)
        var options = ReplayOptions()
        options.quality = .low
        options.maskStyle = .solid
        let label = CGRect(x: 20, y: 800, width: 200, height: 30)
        let pending = PendingFrame(image: PrivacyFuzzPalette.solidImage(.white, size: size), redactions: [label],
                                   timestamp: Date())
        let frame = try XCTUnwrap(RedactionPainter.redactAndCompress(pending, options: options))
        let bitmap = try XCTUnwrap(PrivacyFuzzBitmap(jpeg: frame.jpeg))

        let scaleY = frame.size.height / size.height
        let topRow = Int((label.minY * scaleY).rounded(.down))
        let p = bitmap.pixel(Int(label.midX * frame.size.width / size.width), topRow)
        XCTAssertLessThan(max(p.r, p.g, p.b), 100,
                          "top row \(topRow) of a mask at y=\(label.minY)pt is \(p), not black (output \(frame.size))")
    }

    /// Non-finite and degenerate rects must be skipped without corrupting the frame.
    func testNonFiniteRectsLeaveTheFrameIntact() throws {
        let size = CGSize(width: 101, height: 57)
        let hostile: [CGRect] = [
            CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
            CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10),
            CGRect(x: -CGFloat.infinity, y: -CGFloat.infinity, width: CGFloat.infinity, height: CGFloat.infinity),
            .null, .infinite, .zero,
            CGRect(x: 0, y: 0, width: CGFloat.nan, height: CGFloat.nan),
        ]
        let pending = PendingFrame(image: PrivacyFuzzPalette.solidImage(.white, size: size), redactions: hostile,
                                   timestamp: Date())
        let frame = try XCTUnwrap(RedactionPainter.redactAndCompress(pending, options: ReplayOptions()))
        let bitmap = try XCTUnwrap(PrivacyFuzzBitmap(jpeg: frame.jpeg))
        // `.zero` paints only its 2pt padding at the origin; the middle must still be white.
        let middle = bitmap.pixel(bitmap.width / 2, bitmap.height / 2)
        XCTAssertGreaterThan(min(middle.r, middle.g, middle.b), 200, "hostile rects blacked out the frame: \(middle)")
    }

    // MARK: - Skeleton style

    /// A text or sensitive mask takes every colour from outside itself, so two frames that
    /// differ only inside the mask must encode to the same bytes.
    func testSkeletonTextAndSensitiveMasksDoNotDependOnWhatTheyCover() throws {
        for seed in PrivacyFuzzConfig.seeds(default: 24, slowDivisor: 4) {
            var rng = PrivacyFuzzRNG(seed: seed)
            let size = CGSize(width: rng.cgFloat(120...500), height: rng.cgFloat(120...900))
            var options = ReplayOptions()
            options.quality = rng.pick(ReplayQuality.allCases)
            let rects = (0..<rng.int(1...6)).map { _ in
                CGRect(x: rng.cgFloat(0...(size.width - 20)), y: rng.cgFloat(0...(size.height - 20)),
                       width: rng.cgFloat(4...120), height: rng.cgFloat(4...90))
            }
            let kinds = rects.map { _ in rng.pick([MaskKind.text, .image, .unknown]) }
            // Image masks may carry a muted tint of what they cover; make every non-text one sensitive.
            let sensitive = zip(rects, kinds).filter { $0.1 != .text }.map(\.0)
            let background = rng.pick(PrivacyFuzzPalette.safe)
            func frame(covering fill: UIColor) throws -> Data {
                let image = imageWithBlocks(size: size, background: background, blocks: rects, fill: fill)
                let pending = PendingFrame(image: image, redactions: rects, kinds: kinds, timestamp: Date(), sensitive: sensitive)
                let redacted = try XCTUnwrap(RedactionPainter.redact(pending, options: options))
                let raw = try XCTUnwrap(redacted.dataProvider?.data as Data?)
                // RGB only: the fourth byte of a skip-alpha bitmap is padding.
                return Data(raw.enumerated().filter { $0.offset % 4 != 3 }.map(\.element))
            }
            let context = "\(PrivacyFuzzConfig.describe(seed)) size=\(size) rects=\(rects) kinds=\(kinds)"
            // Raw pixels rather than JPEG bytes, so a failure points at the painter.
            XCTAssertEqual(try frame(covering: PrivacyFuzzPalette.sentinel), try frame(covering: .black),
                           "PRIVACY LEAK (skeleton): masked content changed the output. \(context)")
        }
    }

    /// Whatever kind a mask is, the content under it never survives, image tints included.
    func testSkeletonMasksLeaveNoSentinelPixels() throws {
        var checked = 0
        for seed in PrivacyFuzzConfig.seeds(default: 40, slowDivisor: 4) {
            var rng = PrivacyFuzzRNG(seed: seed)
            let size = randomSourceSize(&rng)
            guard size.width >= 8, size.height >= 8, size.width < 3000, size.height < 3000 else { continue }
            var options = ReplayOptions()
            options.quality = rng.pick(ReplayQuality.allCases)
            let rects = (0..<rng.int(1...10)).map { _ in randomRect(&rng, in: size) }
                .filter(RedactionPainter.isFinite)
                .map { $0.standardized.intersection(CGRect(origin: .zero, size: size)) }
                .filter { !$0.isNull && $0.width >= 1 && $0.height >= 1 }
            guard !rects.isEmpty else { continue }
            let kinds = rects.map { _ in rng.pick([MaskKind.text, .image, .unknown]) }
            let image = imageWithBlocks(size: size, background: rng.pick(PrivacyFuzzPalette.safe), blocks: rects,
                                        fill: PrivacyFuzzPalette.sentinel)
            let pending = PendingFrame(image: image, redactions: rects, kinds: kinds, timestamp: Date())
            let frame = try XCTUnwrap(RedactionPainter.redactAndCompress(pending, options: options))
            let leak = try XCTUnwrap(PrivacyFuzzBitmap(jpeg: frame.jpeg)).sentinelPixels()
            checked += 1
            XCTAssertEqual(leak.count, 0, "PRIVACY LEAK (skeleton): \(PrivacyFuzzConfig.describe(seed)) size=\(size) "
                           + "rects=\(rects) kinds=\(kinds) first=\(leak.samples)")
        }
        XCTAssertGreaterThan(checked, 0, "no frame was checked")
    }

    private func imageWithBlocks(size: CGSize, background: UIColor, blocks: [CGRect], fill: UIColor) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard // as ViewCapture captures
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            fill.setFill()
            for block in blocks { context.fill(block) }
        }
    }

    // MARK: - Generators

    private func randomSourceSize(_ rng: inout PrivacyFuzzRNG) -> CGSize {
        switch rng.int(0...9) {
        case 0: return CGSize(width: 1, height: 1)
        case 1: return CGSize(width: rng.pick([1, 2, 3]), height: rng.int(1...300))
        // Rare and big: the 2048 ceiling path. Kept rare because each costs a 16 MB bitmap.
        case 2: return rng.chance(0.3) ? CGSize(width: rng.int(1500...2048), height: rng.int(1500...2600)) : CGSize(width: 77, height: 1)
        default: return CGSize(width: rng.int(1...600), height: rng.int(1...900))
        }
    }

    private func randomRect(_ rng: inout PrivacyFuzzRNG, in size: CGSize) -> CGRect {
        let weird: [CGFloat] = [.nan, .infinity, -.infinity, 0, -0.0, 1e30, -1e30, 1e300, .greatestFiniteMagnitude, 0.25]
        func coordinate(_ extent: CGFloat) -> CGFloat {
            rng.chance(0.15) ? rng.pick(weird) : rng.cgFloat(-extent * 0.5...extent * 1.2)
        }
        func length(_ extent: CGFloat) -> CGFloat {
            rng.chance(0.15) ? rng.pick(weird) : rng.cgFloat(-extent * 0.5...extent * 1.2)
        }
        return CGRect(x: coordinate(size.width), y: coordinate(size.height),
                      width: length(size.width), height: length(size.height))
    }

    private func samplePoints(in rect: CGRect) -> [(Int, Int)] {
        let xs = [rect.minX, rect.midX, rect.maxX - 0.01].map { Int($0.rounded(.down)) }
        let ys = [rect.minY, rect.midY, rect.maxY - 0.01].map { Int($0.rounded(.down)) }
        return xs.flatMap { x in ys.map { (x, $0) } }
    }
}
