import UIKit
import XCTest
@testable import MapleReplay

/// Masks during Core Animation transitions.
///
/// The capture draws the render server's committed frame, which mid-animation is the
/// presentation tree, while the view tree already holds the end state. A mask taken only
/// from the view tree lands where the view is going and leaves the text visible where it
/// is drawn.
@MainActor
final class AnimationRedactionTests: XCTestCase {
    private func window() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        window.rootViewController = UIViewController()
        window.isHidden = false
        return window
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testMasksWhereAnAnimatingLabelIsDrawnAsWellAsWhereItIsGoing() throws {
        let window = window()
        let root = try XCTUnwrap(window.rootViewController?.view)
        let label = UILabel(frame: CGRect(x: 0, y: 100, width: 80, height: 20))
        label.text = "4111 1111 1111 1111"
        root.addSubview(label)
        settle()

        UIView.animate(withDuration: 30, delay: 0, options: [.curveLinear]) {
            label.frame.origin.x = 300
        }
        settle()

        let presented = try XCTUnwrap(label.layer.presentation(), "no presentation layer: nothing to assert")
        let drawnAt = presented.convert(presented.bounds, to: window.layer.presentation() ?? window.layer)
        XCTAssertLessThan(drawnAt.minX, 100, "the label should still be near its start")

        let rects = RedactionScanner(options: ReplayOptions()).rects(in: window)
        let drawnCovered = rects.contains { $0.insetBy(dx: -1, dy: -1).contains(drawnAt) }
        let targetCovered = rects.contains {
            $0.insetBy(dx: -1, dy: -1).contains(CGRect(x: 300, y: 100, width: 80, height: 20))
        }
        XCTAssertTrue(drawnCovered, "drawn position \(drawnAt) unmasked; rects: \(rects)")
        XCTAssertTrue(targetCovered, "model position unmasked; rects: \(rects)")
    }

    func testAStaticScreenGetsOneMaskPerLabel() throws {
        let window = window()
        let root = try XCTUnwrap(window.rootViewController?.view)
        let label = UILabel(frame: CGRect(x: 10, y: 100, width: 80, height: 20))
        label.text = "static"
        root.addSubview(label)
        settle()

        let rects = RedactionScanner(options: ReplayOptions()).rects(in: window)
        XCTAssertEqual(rects, [CGRect(x: 10, y: 100, width: 80, height: 20)])
    }
}
