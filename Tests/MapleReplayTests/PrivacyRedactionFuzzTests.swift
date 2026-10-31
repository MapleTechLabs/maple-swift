import UIKit
import XCTest
@testable import MapleReplay

/// Rect-level privacy fuzzing: random UIKit trees against an oracle that restates the
/// masking contract independently of `RedactionScanner`.
///
/// Reproduce one failure with the seed it prints:
/// `TEST_RUNNER_MAPLE_FUZZ_SEED=0x... TEST_RUNNER_MAPLE_FUZZ_ITERATIONS=1`.
/// Leaks are bucketed by known cause so a soak's summary shows anything new at a glance;
/// each bucket reports its first few seeds in full.
@MainActor
final class PrivacyRedactionFuzzTests: XCTestCase {
    private var tally: [String: Int] = [:]
    private var iterations = 0

    override func tearDown() {
        if !tally.isEmpty {
            print("privacy fuzz \(name): \(iterations) trees, leaks by cause: "
                  + tally.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))
        }
        super.tearDown()
    }

    /// Every visible sensitive view's drawn region is inside the scanner's rects, every
    /// rect is finite, non-empty and inside the root, and the scan is deterministic.
    func testRandomTreesNeverExposeSensitiveViews() {
        for seed in PrivacyFuzzConfig.seeds(default: 200) {
            iterations += 1
            var rng = PrivacyFuzzRNG(seed: seed)
            let root = UIView(frame: CGRect(x: 0, y: 0, width: 360, height: 640))
            let tree = PrivacyFuzzTreeGenerator.populate(root, rng: &rng)
            let scanner = RedactionScanner(options: tree.options)
            let result = scanner.scan(in: root)

            let again = scanner.scan(in: root)
            if again != result {
                report("nondeterministic", "\(PrivacyFuzzConfig.describe(seed)) scan is not deterministic: \(result) vs \(again)")
            }
            for problem in PrivacyFuzzOracle.rectProblems(result.rects, root: root) {
                report("invalid-rect", "\(PrivacyFuzzConfig.describe(seed)) \(problem)")
            }
            checkCoverage(tree, rects: result.rects, seed: seed, presentation: false)
        }
    }

    /// Mid-animation the frame shows the presentation tree. Sensitive views must be
    /// covered where they are drawn now as well as where they are going.
    func testAnimatingTreesNeverExposeSensitiveViews() {
        var animatedSensitive = 0
        for seed in PrivacyFuzzConfig.seeds(default: 20, slowDivisor: 8) {
            iterations += 1
            var rng = PrivacyFuzzRNG(seed: seed)
            let (window, content) = PrivacyFuzzWindow.make()
            defer { PrivacyFuzzWindow.tearDown(window) }
            var tree = PrivacyFuzzTreeGenerator.populate(content, rng: &rng, maxDepth: 5, maxViews: 30)
            tree = PrivacyFuzzTree(root: window, views: tree.views, options: tree.options, names: tree.names)
            PrivacyFuzzWindow.settle(0.05)

            for view in tree.views where rng.chance(0.35) {
                animate(view, rng: &rng)
            }
            PrivacyFuzzWindow.settle(rng.pick([0.05, 0.15, 0.3]))

            let sensitive = PrivacyFuzzOracle.sensitiveViews(in: window, options: tree.options, only: tree.views)
            animatedSensitive += sensitive.filter { hasAnimatingAncestorOrSelf($0.view) }.count

            let rects = RedactionScanner(options: tree.options).rects(in: window)
            for problem in PrivacyFuzzOracle.rectProblems(rects, root: window) {
                report("invalid-rect", "\(PrivacyFuzzConfig.describe(seed)) \(problem)")
            }
            checkCoverage(tree, rects: rects, seed: seed, presentation: false)
            checkCoverage(tree, rects: rects, seed: seed, presentation: true)
        }
        XCTAssertGreaterThan(animatedSensitive, 0, "no sensitive view was ever animated: the fuzzer proved nothing")
    }

    // MARK: - Helpers

    private func animate(_ view: UIView, rng: inout PrivacyFuzzRNG) {
        let duration = rng.pick([20.0, 40.0])
        let kind = rng.int(0...4)
        let dx = rng.cgFloat(-300...300), dy = rng.cgFloat(-300...300)
        UIView.animate(withDuration: duration, delay: 0, options: [.curveLinear]) {
            switch kind {
            case 0: view.center = CGPoint(x: view.center.x + dx, y: view.center.y + dy)
            case 1: view.transform = CGAffineTransform(scaleX: 2.5, y: 0.4).rotated(by: 0.7)
            case 2: view.bounds.size = CGSize(width: abs(dx) + 1, height: abs(dy) + 1)
            // Fades: the model says invisible long before the screen does.
            case 3: view.alpha = 0
            default: view.frame = view.frame.offsetBy(dx: dx, dy: 0).insetBy(dx: -20, dy: -20)
            }
        }
    }

    private func hasAnimatingAncestorOrSelf(_ view: UIView) -> Bool {
        var cursor: UIView? = view
        while let current = cursor {
            if !(current.layer.animationKeys() ?? []).isEmpty { return true }
            cursor = current.superview
        }
        return false
    }

    /// Reports in full only the first few of each cause, so a known bug cannot bury a
    /// new one; the tally in `tearDown` still counts every occurrence.
    private func report(_ cause: String, _ message: String) {
        tally[cause, default: 0] += 1
        if tally[cause, default: 0] <= 3 { XCTFail("[\(cause)] \(message)") }
    }

    private func checkCoverage(_ tree: PrivacyFuzzTree, rects: [CGRect], seed: UInt64, presentation: Bool) {
        for item in PrivacyFuzzOracle.sensitiveViews(in: tree.root, options: tree.options, only: tree.views) {
            guard PrivacyFuzzOracle.isVisible(item.view, root: tree.root, presentation: presentation) else { continue }
            guard let point = PrivacyFuzzOracle.uncoveredPoint(
                of: item.view, root: tree.root, rects: rects, presentation: presentation,
                tolerance: presentation ? 1 : 0.5
            ) else { continue }
            report(cause(of: item, tree: tree, point: point, presentation: presentation), """
            \(PrivacyFuzzConfig.describe(seed)) PRIVACY LEAK (\(presentation ? "presentation" : "model") geometry): \
            \(tree.name(item.view)) [\(item.reason)] drawn at \(point) is outside every rect.
            options: \(tree.describeOptions())
            minimized chain from root:
            \(tree.chain(to: item.view))
            rects: \(rects.map(PrivacyFuzzTree.fmt))
            """)
        }
    }

    /// Buckets a leak by the known causes in `PrivacyLeakRegressionTests`; "unexplained"
    /// is the bucket to read after a soak.
    private func cause(of item: PrivacyFuzzOracle.Sensitive, tree: PrivacyFuzzTree, point: CGPoint, presentation: Bool)
        -> String
    {
        let view = item.view
        if item.reason.contains("inside an unmasked ancestor") { return "mask-inside-unmask" }
        if item.reason == "secure text entry" {
            let classUnmasked = tree.options.unmaskedViewClasses.contains {
                ObjectIdentifier($0) == ObjectIdentifier(type(of: view))
            }
            if view.mapleReplayMaskOverride == false || classUnmasked { return "secure-self-unmasked" }
            if !(view is UITextInput), !tree.options.maskAllText { return "secure-keyinput-maskAllText-off" }
        }
        if presentation, !PrivacyFuzzOracle.isVisible(view, root: tree.root, presentation: false) {
            return "fade-out"
        }
        var ancestors: [UIView] = []
        var cursor = view.superview
        while let current = cursor, current !== tree.root { ancestors.append(current); cursor = current.superview }
        if ([view] + ancestors).contains(where: { candidate in
            candidate.mapleReplayMaskOverride == true && tree.options.unmaskedViewClasses.contains {
                ObjectIdentifier($0) == ObjectIdentifier(type(of: candidate))
            }
        }) {
            return "instance-mask-loses-to-class-unmask"
        }
        if ancestors.contains(where: { ancestor in
            let box = ancestor.convert(ancestor.bounds, to: tree.root)
            return !box.contains(point) && maskedOutright(ancestor, tree: tree)
        }) {
            return "overflow-of-masked-parent"
        }
        if ancestors.contains(where: { ancestor in
            let box = ancestor.convert(ancestor.bounds, to: tree.root).intersection(tree.root.bounds)
            return !ancestor.clipsToBounds && (box.isNull || box.width <= 0 || box.height <= 0)
        }) {
            return "empty-or-offscreen-ancestor"
        }
        return "unexplained"
    }

    private func maskedOutright(_ view: UIView, tree: PrivacyFuzzTree) -> Bool {
        PrivacyFuzzOracle.sensitiveViews(in: tree.root, options: tree.options)
            .contains { $0.view === view && !$0.reason.hasPrefix("inside") }
    }
}
