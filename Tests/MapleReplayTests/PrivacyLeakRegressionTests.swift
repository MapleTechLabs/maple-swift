import UIKit
import XCTest
@testable import MapleReplay

/// Minimized repros of leaks the privacy fuzzers found. Each names the fuzz seed it was
/// reduced from (default seed base, see `PrivacyFuzzConfig`).
@MainActor
final class PrivacyLeakRegressionTests: XCTestCase {
    private func root() -> UIView {
        UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 640))
    }

    private func covers(_ rects: [CGRect], _ target: CGRect) -> Bool {
        rects.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(target) }
    }

    // MARK: - A clipped-away or empty ancestor hides its whole subtree

    /// From seed 0xf93923002909d63d. A zero-size, non-clipping container still draws its
    /// children, but the scanner drops the subtree when the container's own rect is empty.
    func testChildOfAZeroSizeNonClippingParentIsMasked() {
        let container = root()
        let anchor = UIView(frame: CGRect(x: 100, y: 100, width: 0, height: 0))
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        field.text = "4111 1111 1111 1111"
        anchor.addSubview(field)
        container.addSubview(anchor)

        let rects = RedactionScanner(options: ReplayOptions()).rects(in: container)
        XCTAssertTrue(covers(rects, CGRect(x: 100, y: 100, width: 200, height: 30)),
                      "text field drawn at (100,100 200x30) is unmasked; rects: \(rects)")
    }

    /// Same cause: a non-clipping parent laid out off screen with a child positioned back
    /// on screen (a common slide-in container pattern).
    func testOnScreenChildOfAnOffScreenNonClippingParentIsMasked() {
        let container = root()
        let parent = UIView(frame: CGRect(x: -500, y: 100, width: 100, height: 100))
        let field = UITextField(frame: CGRect(x: 520, y: 0, width: 200, height: 30))
        field.isSecureTextEntry = true
        field.text = "hunter2"
        parent.addSubview(field)
        container.addSubview(parent)

        let rects = RedactionScanner(options: ReplayOptions()).rects(in: container)
        XCTAssertTrue(covers(rects, CGRect(x: 20, y: 100, width: 200, height: 30)),
                      "secure field drawn at (20,100 200x30) is unmasked; rects: \(rects)")
    }

    // MARK: - Secure entry reached by an opt-out

    /// From seed 0x7cfd117743fb6b1f. `mapleReplayUnmask()` on the secure view itself skips
    /// the secure check, which only runs for descendants of an unmasked view.
    func testSecureFieldMarkedUnmaskIsStillMasked() {
        let container = root()
        let field = UITextField(frame: CGRect(x: 10, y: 10, width: 200, height: 30))
        field.isSecureTextEntry = true
        field.text = "hunter2"
        field.mapleReplayUnmask()
        container.addSubview(field)

        let rects = RedactionScanner(options: ReplayOptions()).rects(in: container)
        XCTAssertTrue(covers(rects, field.frame), "secure field unmasked by its own opt-out; rects: \(rects)")
    }

    /// From seed 0x2405b99c3a0e3445. The same through `unmaskedViewClasses`.
    func testSecureFieldWhoseClassIsUnmaskedIsStillMasked() {
        var options = ReplayOptions()
        options.unmaskedViewClasses = [UITextField.self]
        let container = root()
        let field = UITextField(frame: CGRect(x: 10, y: 10, width: 200, height: 30))
        field.isSecureTextEntry = true
        container.addSubview(field)

        let rects = RedactionScanner(options: options).rects(in: container)
        XCTAssertTrue(covers(rects, field.frame), "secure field unmasked by its class; rects: \(rects)")
    }

    /// A passcode view built on `UIKeyInput` is secure entry but not `UITextInput`, and
    /// with `maskAllText` off nothing else catches it.
    func testSecureKeyInputViewIsMaskedWithTextMaskingOff() {
        var options = ReplayOptions()
        options.maskAllText = false
        let container = root()
        let pin = PrivacyFuzzKeyInputView(frame: CGRect(x: 10, y: 10, width: 200, height: 40))
        pin.isSecureTextEntry = true
        container.addSubview(pin)

        let rects = RedactionScanner(options: options).rects(in: container)
        XCTAssertTrue(covers(rects, pin.frame), "secure UIKeyInput view unmasked; rects: \(rects)")
    }

    // MARK: - Explicit masks inside an unmask

    /// From seed 0x799ee6d45c16f055. `mapleReplayMask()` promises "whatever the masking
    /// options say", but beneath any unmasked ancestor only secure entry is checked.
    func testExplicitMaskInsideAnUnmaskedClassIsHonoured() {
        var options = ReplayOptions()
        options.unmaskedViewClasses = [UIView.self]
        let container = root()
        let card = PrivacyFuzzContainer(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        card.mapleReplayMask()
        let field = UITextField(frame: CGRect(x: 0, y: 300, width: 200, height: 30))
        container.addSubview(card)
        container.addSubview(field)

        // The root is a plain UIView, so naming UIView unmasks the whole screen.
        let rects = RedactionScanner(options: options).rects(in: container)
        XCTAssertTrue(covers(rects, card.frame), "mapleReplayMask() view unmasked; rects: \(rects)")
        XCTAssertTrue(covers(rects, field.frame),
                      "text field unmasked because an ancestor's class was named; rects: \(rects)")
    }

    /// From seed 0x094470864a6607ff. `isExplicitlyUnmasked` checks the class list even
    /// when the instance itself says `mapleReplayMask()`, so the class-wide opt-out wins
    /// over the more specific per-view mask.
    func testInstanceMaskBeatsAnUnmaskedClass() {
        var options = ReplayOptions()
        options.unmaskedViewClasses = [UIImageView.self]
        let container = root()
        let avatar = UIImageView(frame: CGRect(x: 10, y: 10, width: 120, height: 120))
        avatar.image = PrivacyFuzzPalette.solidImage(.gray, size: CGSize(width: 12, height: 12))
        avatar.mapleReplayMask()
        container.addSubview(avatar)

        let rects = RedactionScanner(options: options).rects(in: container)
        XCTAssertTrue(covers(rects, avatar.frame), "mapleReplayMask() lost to unmaskedViewClasses; rects: \(rects)")
    }

    func testExplicitMaskInsideAnUnmaskedViewIsHonoured() {
        let container = root()
        let region = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 400))
        region.mapleReplayUnmask()
        let balance = UILabel(frame: CGRect(x: 10, y: 10, width: 200, height: 30))
        balance.text = "$12,345.67"
        balance.mapleReplayMask()
        region.addSubview(balance)
        container.addSubview(region)

        let rects = RedactionScanner(options: ReplayOptions()).rects(in: container)
        XCTAssertTrue(covers(rects, balance.frame), "re-masked label inside an unmask is exposed; rects: \(rects)")
    }

    // MARK: - Content outside a masked parent

    /// Masking a view masks its bounds and stops the walk, so a non-clipping child drawn
    /// outside those bounds is never examined, though on its own it would be masked.
    func testOverflowingChildOfAMaskedParentIsMasked() {
        let container = root()
        let card = UIView(frame: CGRect(x: 10, y: 10, width: 100, height: 100))
        card.mapleReplayMask()
        let label = UILabel(frame: CGRect(x: 120, y: 0, width: 150, height: 30))
        label.text = "ada@example.com"
        card.addSubview(label)
        container.addSubview(card)

        let rects = RedactionScanner(options: ReplayOptions()).rects(in: container)
        XCTAssertTrue(covers(rects, CGRect(x: 130, y: 10, width: 150, height: 30)),
                      "label overflowing a masked card is unmasked; rects: \(rects)")
    }

    /// From seeds 0x3249ebd03fba539d and 0xd95293f535cd1cc3 (pixel fuzzer). A
    /// non-clipping `UIImageView` whose content mode does not scale (`.center`, `.top...`,
    /// `.scaleAspectFill`) draws its image past its bounds, and the mask covers only the
    /// bounds. Checked on pixels, through the scan and the painter.
    func testImageDrawnPastItsBoundsIsMasked() throws {
        let (window, content) = PrivacyFuzzWindow.make()
        defer { PrivacyFuzzWindow.tearDown(window) }
        content.backgroundColor = .white
        let avatar = UIImageView(frame: CGRect(x: 100, y: 100, width: 40, height: 40))
        avatar.contentMode = .scaleAspectFill
        avatar.image = PrivacyFuzzPalette.solidImage(PrivacyFuzzPalette.sentinel, size: CGSize(width: 160, height: 80))
        content.addSubview(avatar)
        window.layoutIfNeeded()
        PrivacyFuzzWindow.settle(0.1)

        let (pending, _) = try XCTUnwrap(PrivacyFuzzWindow.capture(window, options: ReplayOptions()))
        let raw = try XCTUnwrap(pending.image.cgImage.flatMap(PrivacyFuzzBitmap.init(cgImage:)))
        XCTAssertGreaterThan(raw.sentinelPixels(limit: 1).count, 0, "the image was not drawn: nothing to assert")
        let frame = try XCTUnwrap(RedactionPainter.redactAndCompress(pending, options: ReplayOptions()))
        let leak = try XCTUnwrap(PrivacyFuzzBitmap(jpeg: frame.jpeg)).sentinelPixels()
        XCTAssertEqual(leak.count, 0, "image pixels outside the image view survived, e.g. \(leak.samples); rects: \(pending.redactions)")
    }

    // MARK: - Fades

    /// From seed 0x20a78ef95229b97b. Fading a view out sets its model alpha to 0 at once,
    /// and the scanner skips it while the screen still shows it for the whole fade.
    func testFadingOutLabelIsMaskedWhileStillOnScreen() throws {
        let (window, content) = PrivacyFuzzWindow.make()
        defer { PrivacyFuzzWindow.tearDown(window) }
        let label = UILabel(frame: CGRect(x: 20, y: 100, width: 200, height: 30))
        label.text = "4111 1111 1111 1111"
        content.addSubview(label)
        PrivacyFuzzWindow.settle(0.1)

        UIView.animate(withDuration: 30, delay: 0, options: [.curveLinear]) { label.alpha = 0 }
        PrivacyFuzzWindow.settle(0.2)

        let presented = try XCTUnwrap(label.layer.presentation(), "no presentation layer: nothing to assert")
        XCTAssertGreaterThan(presented.opacity, 0.9, "the label should still be almost fully drawn")
        let rects = RedactionScanner(options: ReplayOptions()).rects(in: window)
        XCTAssertTrue(covers(rects, CGRect(x: 20, y: 100, width: 200, height: 30)),
                      "fading label at opacity \(presented.opacity) is unmasked; rects: \(rects)")
    }
}
