import UIKit
import XCTest
@testable import MapleReplay

@MainActor
final class RedactionScannerTests: XCTestCase {
    private var options = ReplayOptions()

    private func root() -> UIView {
        UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
    }

    private func scan(_ view: UIView) -> [CGRect] {
        RedactionScanner(options: options).rects(in: view)
    }

    // MARK: - The rule that makes SwiftUI tractable

    /// An unrecognised leaf that draws its own content is masked.
    ///
    /// SwiftUI renders through private UIKit classes whose names change between releases —
    /// the failure that forces wireframe recorders to ship per-iOS-version lookup tables.
    /// We identify content structurally instead, so an unrecognised drawing leaf produces
    /// an over-broad mask rather than a leak.
    func testUnknownDrawingLeafIsMasked() {
        final class PrivateDrawingLeaf: UIView {
            override func draw(_ rect: CGRect) {}
        }
        let container = root()
        container.addSubview(PrivateDrawingLeaf(frame: CGRect(x: 10, y: 20, width: 100, height: 30)))

        XCTAssertEqual(scan(container), [CGRect(x: 10, y: 20, width: 100, height: 30)])
    }

    /// A leaf whose layer carries a bitmap is content, whatever its class is called.
    func testUnknownLeafWithLayerContentsIsMasked() {
        final class PrivateImageLeaf: UIView {}
        let container = root()
        let leaf = PrivateImageLeaf(frame: CGRect(x: 0, y: 0, width: 80, height: 80))
        leaf.layer.contents = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
            .image { $0.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }.cgImage
        container.addSubview(leaf)

        XCTAssertEqual(scan(container).count, 1)
    }

    /// The counterpart, and the reason the whole screen doesn't go black: a view that can
    /// only paint `backgroundColor` carries no information, whatever its class is called.
    /// UIKit's full-screen list decoration and background views are exactly this — and
    /// masking them redacts the entire screen.
    func testNonDrawingLeafIsNotMasked() {
        final class PrivateBackgroundLeaf: UIView {}
        let container = root()
        let background = PrivateBackgroundLeaf(frame: container.bounds)
        background.backgroundColor = .systemGroupedBackground
        container.addSubview(background)
        container.addSubview(UIView(frame: CGRect(x: 0, y: 0, width: 100, height: 100)))

        XCTAssertTrue(scan(container).isEmpty)
    }

    func testInertContainersAreNotMaskedThemselves() {
        let container = root()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        container.addSubview(scrollView)

        XCTAssertTrue(scan(container).isEmpty)
    }

    // MARK: - Explicit sensitive types

    func testLabelIsMaskedWhenMaskAllTextIsOn() {
        let container = root()
        container.addSubview(UILabel(frame: CGRect(x: 5, y: 5, width: 200, height: 20)))

        XCTAssertEqual(scan(container), [CGRect(x: 5, y: 5, width: 200, height: 20)])
    }

    func testTextFieldIsMaskedEvenWithTextMaskingDisabled() {
        options.maskAllText = false
        options.maskAllImages = false
        let container = root()
        container.addSubview(UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 30)))

        // Text entry is inherently sensitive regardless of configuration.
        XCTAssertEqual(scan(container).count, 1)
    }

    /// Small vector icons stay visible — masking them costs readability and buys no
    /// privacy, and a replay of solid blocks is not worth recording.
    func testSmallSymbolIsTreatedAsChrome() {
        let container = root()
        let chevron = UIImageView(frame: CGRect(x: 350, y: 10, width: 20, height: 20))
        chevron.image = UIImage(systemName: "chevron.right")
        container.addSubview(chevron)

        XCTAssertTrue(scan(container).isEmpty)
    }

    /// Size dominates: a symbol drawn at content size is masked like any other image.
    /// Checking symbol-ness first would let a full-bleed SF Symbol through unmasked.
    func testLargeSymbolIsStillMasked() {
        let container = root()
        let hero = UIImageView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        hero.image = UIImage(systemName: "photo")
        container.addSubview(hero)

        XCTAssertEqual(scan(container), [CGRect(x: 0, y: 0, width: 300, height: 200)])
    }

    /// The case size-only heuristics get wrong: a 40pt avatar is chrome-sized but is
    /// precisely the PII this is meant to catch.
    func testSmallNonSymbolImageIsMasked() {
        let container = root()
        let avatar = UIImageView(frame: CGRect(x: 10, y: 10, width: 40, height: 40))
        avatar.image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        container.addSubview(avatar)

        XCTAssertEqual(scan(container), [CGRect(x: 10, y: 10, width: 40, height: 40)])
    }

    // MARK: - Configuration

    func testUnmaskedViewClassesOptOutWins() {
        final class SafeBadge: UILabel {}
        options.unmaskedViewClasses = [SafeBadge.self]
        let container = root()
        container.addSubview(SafeBadge(frame: CGRect(x: 0, y: 0, width: 50, height: 20)))

        XCTAssertTrue(scan(container).isEmpty)
    }

    func testMaskedViewClassesForceMasking() {
        final class CustomChart: UIView {}
        options.maskedViewClasses = [CustomChart.self]
        let container = root()
        let chart = CustomChart(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        // Give it a child so the unknown-leaf rule can't be what masks it.
        chart.addSubview(UIView(frame: .zero))
        container.addSubview(chart)

        XCTAssertEqual(scan(container).count, 1)
    }

    func testHiddenAndTransparentViewsAreSkipped() {
        let container = root()
        let hidden = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
        hidden.isHidden = true
        let transparent = UILabel(frame: CGRect(x: 0, y: 40, width: 100, height: 20))
        transparent.alpha = 0
        container.addSubview(hidden)
        container.addSubview(transparent)

        XCTAssertTrue(scan(container).isEmpty)
    }

    // MARK: - Coordinate conversion

    func testNestedViewRectIsConvertedToRootSpace() {
        let container = root()
        let middle = UIView(frame: CGRect(x: 50, y: 100, width: 300, height: 400))
        let label = UILabel(frame: CGRect(x: 10, y: 20, width: 100, height: 30))
        middle.addSubview(label)
        container.addSubview(middle)

        XCTAssertEqual(scan(container), [CGRect(x: 60, y: 120, width: 100, height: 30)])
    }

    /// Scrolled content must be reported where it is drawn, not where it is laid out.
    /// A recorder that misses this masks empty space and leaves the real text visible.
    func testScrolledContentIsOffsetByContentOffset() {
        let container = root()
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        scrollView.contentSize = CGSize(width: 400, height: 1_200)
        let label = UILabel(frame: CGRect(x: 0, y: 500, width: 200, height: 40))
        scrollView.addSubview(label)
        container.addSubview(scrollView)

        scrollView.contentOffset = CGPoint(x: 0, y: 450)

        XCTAssertEqual(scan(container), [CGRect(x: 0, y: 50, width: 200, height: 40)])
    }

    func testTransformedViewRectCoversItsDrawnBounds() {
        let container = root()
        let label = UILabel(frame: CGRect(x: 100, y: 100, width: 100, height: 50))
        container.addSubview(label)
        label.transform = CGAffineTransform(scaleX: 2, y: 2)

        // Scaling about the centre doubles the drawn size around the same midpoint.
        XCTAssertEqual(scan(container), [CGRect(x: 50, y: 75, width: 200, height: 100)])
    }

    // MARK: - Merging

    /// Overlapping rects are kept separate, never unioned.
    ///
    /// Unioning looks like free deduplication and is a runaway: each union grows the
    /// rect, the grown rect intersects more neighbours, and a column of slightly
    /// overlapping rows collapses into one full-screen mask. Overlapping opaque fills
    /// cost nothing to paint, so there is no reason to take that risk.
    func testOverlappingRectsAreNotUnioned() {
        let container = root()
        container.addSubview(UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 50)))
        container.addSubview(UILabel(frame: CGRect(x: 40, y: 20, width: 100, height: 50)))

        let rects = scan(container)
        XCTAssertEqual(rects.count, 2)
        XCTAssertFalse(rects.contains { $0.width > 100 || $0.height > 50 })
    }

    /// Containment is the one safe reduction: it can only shrink the set.
    func testContainedRectIsDropped() {
        let container = root()
        let outer = UILabel(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        container.addSubview(outer)
        let inner = UILabel(frame: CGRect(x: 10, y: 10, width: 50, height: 20))
        container.addSubview(inner)

        XCTAssertEqual(scan(container), [CGRect(x: 0, y: 0, width: 200, height: 100)])
    }

    func testDisjointRectsAreKeptSeparate() {
        let container = root()
        container.addSubview(UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 50)))
        container.addSubview(UILabel(frame: CGRect(x: 0, y: 200, width: 100, height: 50)))

        XCTAssertEqual(scan(container).count, 2)
    }

    func testMaskedParentSuppressesDescendantScanning() {
        let container = root()
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 40))
        field.addSubview(UILabel(frame: CGRect(x: 5, y: 5, width: 50, height: 10)))
        container.addSubview(field)

        // One rect for the field, not a second for the inner label.
        XCTAssertEqual(scan(container), [CGRect(x: 0, y: 0, width: 200, height: 40)])
    }
}

final class RedactionPainterTests: XCTestCase {
    /// H.264 chroma subsampling requires even dimensions; AVAssetWriter accepts odd ones
    /// and then produces a file that decodes to garbage.
    func testScaledSizeIsAlwaysEven() {
        for maxDimension in [CGFloat(512), 854, 1_280] {
            let size = RedactionPainter.scaledSize(
                for: CGSize(width: 1_179, height: 2_556), maxDimension: maxDimension
            )
            XCTAssertEqual(Int(size.width) % 2, 0, "width \(size.width) must be even")
            XCTAssertEqual(Int(size.height) % 2, 0, "height \(size.height) must be even")
            XCTAssertLessThanOrEqual(max(size.width, size.height), maxDimension + 1)
        }
    }

    func testAspectRatioIsPreserved() {
        let source = CGSize(width: 1_000, height: 2_000)
        let scaled = RedactionPainter.scaledSize(for: source, maxDimension: 500)
        XCTAssertEqual(scaled.width / scaled.height, source.width / source.height, accuracy: 0.01)
    }

    func testSmallerThanTargetIsNotUpscaled() {
        let scaled = RedactionPainter.scaledSize(for: CGSize(width: 100, height: 200), maxDimension: 512)
        XCTAssertEqual(scaled, CGSize(width: 100, height: 200))
    }
}
