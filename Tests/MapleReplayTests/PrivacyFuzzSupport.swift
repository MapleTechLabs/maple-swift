import CoreGraphics
import Foundation
import UIKit
import XCTest
@testable import MapleReplay

// Shared harness for the Privacy* and Media* fuzzers. Every type is prefixed so a
// fuzzer added by someone else in this target cannot collide with it.

/// SplitMix64: tiny, fast, and fully determined by its seed, so a failing seed replays.
struct PrivacyFuzzRNG: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func chance(_ probability: Double) -> Bool {
        Double.random(in: 0..<1, using: &self) < probability
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &self) }

    mutating func cgFloat(_ range: ClosedRange<CGFloat>) -> CGFloat { CGFloat.random(in: range, using: &self) }

    mutating func pick<T>(_ items: [T]) -> T { items[Int.random(in: 0..<items.count, using: &self)] }
}

/// Iteration count and seed, from `MAPLE_FUZZ_ITERATIONS` and `MAPLE_FUZZ_SEED`.
///
/// Iteration `i` runs with seed `base + i * golden`, so the seed printed for a failing
/// iteration reproduces it alone with `MAPLE_FUZZ_SEED=<seed> MAPLE_FUZZ_ITERATIONS=1`.
enum PrivacyFuzzConfig {
    /// Fixed default so the normal suite is deterministic; soak runs pass a seed or `random`.
    static let defaultSeed: UInt64 = 0x00C0_FFEE_5EED_0001

    static var baseSeed: UInt64 {
        let raw = ProcessInfo.processInfo.environment["MAPLE_FUZZ_SEED"]?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if raw.isEmpty { return defaultSeed }
        if raw == "random" { return UInt64.random(in: 1...UInt64.max) }
        if raw.hasPrefix("0x"), let value = UInt64(raw.dropFirst(2), radix: 16) { return value }
        return UInt64(raw) ?? defaultSeed
    }

    /// `defaultCount` in the normal suite. With the env var set, slow fuzzers run
    /// `value / slowDivisor` so one soak number sizes every fuzzer sensibly.
    static func iterations(default defaultCount: Int, slowDivisor: Int = 1) -> Int {
        guard let raw = ProcessInfo.processInfo.environment["MAPLE_FUZZ_ITERATIONS"],
              let value = Int(raw.trimmingCharacters(in: .whitespaces)), value > 0
        else { return defaultCount }
        return max(1, value / max(1, slowDivisor))
    }

    static func seeds(default defaultCount: Int, slowDivisor: Int = 1) -> [UInt64] {
        let base = baseSeed
        return (0..<iterations(default: defaultCount, slowDivisor: slowDivisor)).map {
            base &+ UInt64($0) &* 0x9E37_79B9_7F4A_7C15
        }
    }

    static func describe(_ seed: UInt64) -> String { String(format: "seed=0x%016llx", seed) }
}

// MARK: - Pixels

/// A decoded bitmap in RGBA8, sRGB.
struct PrivacyFuzzBitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(jpeg: Data) {
        guard let image = UIImage(data: jpeg)?.cgImage else { return nil }
        self.init(cgImage: image)
    }

    init?(cgImage: CGImage) {
        let width = cgImage.width, height = cgImage.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        bytes = buffer
    }

    /// Top-left origin, like UIKit.
    func pixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = (y * width + x) * 4
        return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
    }

    /// Pixels that can only come from the sentinel colour. Far from black and from every
    /// palette colour, so JPEG noise at any tier cannot fake or hide one.
    func sentinelPixels(limit: Int = 8) -> (count: Int, samples: [CGPoint]) {
        var count = 0
        var samples: [CGPoint] = []
        for y in 0..<height {
            for x in 0..<width {
                let p = pixel(x, y)
                if PrivacyFuzzPalette.isSentinel(r: p.r, g: p.g, b: p.b) {
                    count += 1
                    if samples.count < limit { samples.append(CGPoint(x: x, y: y)) }
                }
            }
        }
        return (count, samples)
    }
}

enum PrivacyFuzzPalette {
    /// Pure magenta marks sensitive content. Nothing else in a fuzzed frame uses it.
    static let sentinel = UIColor(red: 1, green: 0, blue: 1, alpha: 1)

    static func isSentinel(r: Int, g: Int, b: Int) -> Bool {
        r >= 170 && b >= 170 && g <= 110 && r - g >= 90 && b - g >= 90
    }

    /// Safe colours: no blend of any two of these, or of these with black or white, can
    /// reach the sentinel test (none has high red and high blue with low green).
    static let safe: [UIColor] = [
        UIColor(white: 0.85, alpha: 1), UIColor(white: 0.25, alpha: 1),
        UIColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1),
        UIColor(red: 0.95, green: 0.85, blue: 0.1, alpha: 1),
        UIColor(red: 1, green: 0.6, blue: 0, alpha: 1),
        UIColor(red: 0, green: 0.75, blue: 0.75, alpha: 1),
    ]

    static func solidImage(_ color: UIColor, size: CGSize, scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Fuzz view classes

/// A container class distinct from UIView, so class lists can name it.
final class PrivacyFuzzContainer: UIView {}

/// A leaf that draws with Core Graphics, the scanner's "unknown drawing leaf".
final class PrivacyFuzzDrawView: UIView {
    var fill: UIColor = .gray { didSet { setNeedsDisplay() } }
    override func draw(_ rect: CGRect) {
        fill.setFill()
        UIRectFill(bounds)
    }
}

/// A custom PIN-pad style input: `UIKeyInput` (so `UITextInputTraits`) but not
/// `UITextInput`, which is the common way to build a passcode entry view.
final class PrivacyFuzzKeyInputView: UIView, UIKeyInput {
    var isSecureTextEntry: Bool = false
    var fill: UIColor = .gray { didSet { setNeedsDisplay() } }
    var hasText: Bool { true }
    func insertText(_ text: String) {}
    func deleteBackward() {}
    override func draw(_ rect: CGRect) {
        fill.setFill()
        UIRectFill(bounds)
    }
}

final class PrivacyFuzzLabel: UILabel {}
final class PrivacyFuzzTextField: UITextField {}

// MARK: - Random UIKit trees

/// A random view tree plus the options it is scanned with.
@MainActor
struct PrivacyFuzzTree {
    let root: UIView
    var views: [UIView] = []
    var options = ReplayOptions()
    /// Names for failure messages, keyed by view identity.
    var names: [ObjectIdentifier: String] = [:]

    func name(_ view: UIView) -> String {
        names[ObjectIdentifier(view)] ?? NSStringFromClass(type(of: view))
    }

    /// One line per view on the path from `root` to `view`, with every property the
    /// scanner reads. This is the minimized repro: siblings are irrelevant to a miss.
    func chain(to view: UIView) -> String {
        var path: [UIView] = []
        var cursor: UIView? = view
        while let current = cursor, current !== root { path.append(current); cursor = current.superview }
        return path.reversed().enumerated().map { depth, v in
            String(repeating: "  ", count: depth) + "- " + Self.describe(v, name: name(v))
        }.joined(separator: "\n")
    }

    static func describe(_ v: UIView, name: String) -> String {
        var parts = ["\(name) frame=\(Self.fmt(v.frame)) bounds=\(Self.fmt(v.bounds))"]
        if v.clipsToBounds { parts.append("clips") }
        if v.isHidden { parts.append("hidden") }
        if v.alpha < 1 { parts.append("alpha=\(v.alpha)") }
        if !v.transform.isIdentity {
            let t = v.transform
            parts.append(String(format: "transform=[%.2f %.2f %.2f %.2f]", t.a, t.b, t.c, t.d))
        }
        if let override = v.mapleReplayMaskOverride { parts.append(override ? "mapleReplayMask()" : "mapleReplayUnmask()") }
        if let traits = v as? UITextInputTraits, traits.isSecureTextEntry == true { parts.append("secure") }
        if !(v.layer.animationKeys() ?? []).isEmpty { parts.append("animating") }
        return parts.joined(separator: " ")
    }

    static func fmt(_ r: CGRect) -> String {
        String(format: "(%.1f,%.1f %.1fx%.1f)", r.origin.x, r.origin.y, r.size.width, r.size.height)
    }

    func describeOptions() -> String {
        let masked = options.maskedViewClasses.map { NSStringFromClass($0) }
        let unmasked = options.unmaskedViewClasses.map { NSStringFromClass($0) }
        return "maskAllText=\(options.maskAllText) maskAllImages=\(options.maskAllImages) "
            + "masked=\(masked) unmasked=\(unmasked)"
    }
}

@MainActor
enum PrivacyFuzzTreeGenerator {
    enum Kind: CaseIterable {
        case container, fuzzContainer, label, fuzzLabel, textField, fuzzTextField, textView,
             imageView, scrollView, stackView, drawLeaf, keyInput
    }

    static let maskableClasses: [AnyClass] = [
        PrivacyFuzzContainer.self, PrivacyFuzzLabel.self, UIImageView.self, PrivacyFuzzDrawView.self,
        UIStackView.self,
    ]
    static let unmaskableClasses: [AnyClass] = [
        PrivacyFuzzContainer.self, PrivacyFuzzLabel.self, UILabel.self, PrivacyFuzzTextField.self,
        UITextField.self, PrivacyFuzzDrawView.self, UIImageView.self, UIView.self,
        PrivacyFuzzKeyInputView.self,
    ]

    static func randomOptions(_ rng: inout PrivacyFuzzRNG) -> ReplayOptions {
        var options = ReplayOptions()
        options.maskAllText = rng.chance(0.7)
        options.maskAllImages = rng.chance(0.7)
        options.maskedViewClasses = maskableClasses.filter { _ in rng.chance(0.15) }
        // Disjoint from the masked list: a class in both is a configuration conflict
        // with no documented winner, not a privacy property.
        options.unmaskedViewClasses = unmaskableClasses.filter { candidate in
            !options.maskedViewClasses.contains { ObjectIdentifier($0) == ObjectIdentifier(candidate) }
                && rng.chance(0.12)
        }
        options.quality = rng.pick(ReplayQuality.allCases)
        return options
    }

    /// Populate `root` with a random tree of up to `maxViews` views and `maxDepth` levels.
    static func populate(_ root: UIView, rng: inout PrivacyFuzzRNG, maxDepth: Int = 6, maxViews: Int = 60)
        -> PrivacyFuzzTree
    {
        var tree = PrivacyFuzzTree(root: root)
        tree.options = randomOptions(&rng)
        var budget = rng.int(1...maxViews)
        grow(root, depth: 0, maxDepth: maxDepth, budget: &budget, rng: &rng, tree: &tree)
        root.layoutIfNeeded()
        return tree
    }

    private static func grow(
        _ parent: UIView, depth: Int, maxDepth: Int, budget: inout Int,
        rng: inout PrivacyFuzzRNG, tree: inout PrivacyFuzzTree
    ) {
        guard depth < maxDepth, budget > 0 else { return }
        let childCount = depth == 0 ? rng.int(1...6) : rng.int(0...4)
        for _ in 0..<childCount where budget > 0 {
            budget -= 1
            let kind = randomKind(&rng)
            let view = make(kind, rng: &rng)
            let index = tree.views.count
            tree.views.append(view)
            tree.names[ObjectIdentifier(view)] = "#\(index) \(NSStringFromClass(type(of: view)))"

            if let stack = parent as? UIStackView, rng.chance(0.8) {
                stack.addArrangedSubview(view)
            } else if let scroll = parent as? UIScrollView {
                scroll.addSubview(view)
                view.frame = randomFrame(in: CGRect(origin: .zero, size: scroll.contentSize), rng: &rng)
            } else {
                parent.addSubview(view)
                view.frame = randomFrame(in: parent.bounds, rng: &rng)
            }
            decorate(view, rng: &rng)

            if isContainer(kind) {
                grow(view, depth: depth + 1, maxDepth: maxDepth, budget: &budget, rng: &rng, tree: &tree)
            }
            if let scroll = view as? UIScrollView {
                scroll.contentOffset = CGPoint(
                    x: rng.cgFloat(-40...max(-40, scroll.contentSize.width)),
                    y: rng.cgFloat(-40...max(-40, scroll.contentSize.height))
                )
            }
        }
    }

    private static func isContainer(_ kind: Kind) -> Bool {
        switch kind {
        case .container, .fuzzContainer, .scrollView, .stackView: return true
        // Occasionally a drawing view with children: it is not a leaf any more.
        default: return false
        }
    }

    private static func randomKind(_ rng: inout PrivacyFuzzRNG) -> Kind {
        let weighted: [(Kind, Int)] = [
            (.container, 18), (.fuzzContainer, 8), (.label, 12), (.fuzzLabel, 4), (.textField, 8),
            (.fuzzTextField, 3), (.textView, 5), (.imageView, 12), (.scrollView, 7), (.stackView, 6),
            (.drawLeaf, 10), (.keyInput, 5),
        ]
        var roll = rng.int(0...(weighted.map(\.1).reduce(0, +) - 1))
        for (kind, weight) in weighted {
            if roll < weight { return kind }
            roll -= weight
        }
        return .container
    }

    private static func make(_ kind: Kind, rng: inout PrivacyFuzzRNG) -> UIView {
        let text = rng.pick(["4111 1111 1111 1111", "ada@example.com", "hunter2", "", "Ada Lovelace",
                             "W", String(repeating: "secret ", count: 12)])
        switch kind {
        case .container: return UIView()
        case .fuzzContainer: return PrivacyFuzzContainer()
        case .label, .fuzzLabel:
            let label = kind == .label ? UILabel() : PrivacyFuzzLabel()
            label.text = text
            label.font = .systemFont(ofSize: rng.cgFloat(8...34), weight: .heavy)
            label.numberOfLines = rng.int(0...2)
            return label
        case .textField, .fuzzTextField:
            let field = kind == .textField ? UITextField() : PrivacyFuzzTextField()
            field.text = text
            field.font = .systemFont(ofSize: rng.cgFloat(10...28), weight: .heavy)
            field.isSecureTextEntry = rng.chance(0.4)
            return field
        case .textView:
            let textView = UITextView()
            textView.text = text
            textView.font = .systemFont(ofSize: rng.cgFloat(10...24), weight: .heavy)
            textView.isSecureTextEntry = rng.chance(0.15)
            return textView
        case .imageView:
            let imageView = UIImageView()
            switch rng.int(0...3) {
            case 0: imageView.image = UIImage(systemName: rng.pick(["chevron.right", "person.fill", "photo"]))
            case 1: imageView.image = PrivacyFuzzPalette.solidImage(.gray, size: CGSize(width: 12, height: 12))
            case 2:
                imageView.image = PrivacyFuzzPalette.solidImage(.gray, size: CGSize(width: 16, height: 16))
                    .withRenderingMode(.alwaysTemplate)
            default: imageView.image = rng.chance(0.5) ? nil
                : PrivacyFuzzPalette.solidImage(.gray, size: CGSize(width: 64, height: 40))
            }
            imageView.contentMode = rng.pick([.scaleToFill, .scaleAspectFit, .center, .topLeft])
            return imageView
        case .scrollView:
            let scroll = UIScrollView()
            scroll.contentSize = CGSize(width: rng.cgFloat(50...900), height: rng.cgFloat(50...1600))
            return scroll
        case .stackView:
            let stack = UIStackView()
            stack.axis = rng.chance(0.5) ? .vertical : .horizontal
            stack.distribution = rng.pick([.fill, .fillEqually, .equalSpacing])
            stack.spacing = rng.cgFloat(0...12)
            return stack
        case .drawLeaf: return PrivacyFuzzDrawView()
        case .keyInput:
            let input = PrivacyFuzzKeyInputView()
            input.isSecureTextEntry = rng.chance(0.6)
            return input
        }
    }

    private static func randomFrame(in parent: CGRect, rng: inout PrivacyFuzzRNG) -> CGRect {
        let w = max(parent.width, 40), h = max(parent.height, 40)
        switch rng.int(0...9) {
        case 0: // Anywhere, often partly or wholly outside the parent.
            return CGRect(x: rng.cgFloat(-w...w), y: rng.cgFloat(-h...h),
                          width: rng.cgFloat(1...w), height: rng.cgFloat(1...h))
        case 1: // Degenerate sizes.
            return CGRect(x: rng.cgFloat(0...w), y: rng.cgFloat(0...h),
                          width: rng.pick([0, -30, 0.3]), height: rng.pick([0, -20, 0.4, 25]))
        case 2: // Far off screen.
            return CGRect(x: rng.pick([-5000, 5000, 380]), y: rng.cgFloat(-h...h), width: 80, height: 40)
        default:
            let width = rng.cgFloat(4...max(4, w * 0.9))
            let height = rng.cgFloat(4...max(4, min(h * 0.6, 260)))
            return CGRect(x: rng.cgFloat(0...max(0, w - width)), y: rng.cgFloat(0...max(0, h - height)),
                          width: width, height: height)
        }
    }

    private static func decorate(_ view: UIView, rng: inout PrivacyFuzzRNG) {
        if rng.chance(0.3) { view.clipsToBounds = true }
        if rng.chance(0.08) { view.isHidden = true }
        if rng.chance(0.15) { view.alpha = rng.pick([0, 0.005, 0.011, 0.02, 0.5]) }
        switch rng.int(0...11) {
        case 0: view.transform = CGAffineTransform(rotationAngle: rng.cgFloat(-.pi...(.pi)))
        case 1: view.transform = CGAffineTransform(scaleX: rng.pick([0, 0.3, 1.7]), y: rng.pick([0, 0.5, 2]))
        case 2: view.transform = CGAffineTransform(translationX: rng.cgFloat(-200...200), y: rng.cgFloat(-200...200))
            .rotated(by: rng.cgFloat(-1...1))
        default: break
        }
        switch rng.int(0...11) {
        case 0: view.mapleReplayMask()
        case 1: view.mapleReplayUnmask()
        default: break
        }
    }
}

// MARK: - Oracle

/// The privacy contract restated independently of the scanner: which views must not
/// survive into a frame, and where they are actually drawn.
@MainActor
enum PrivacyFuzzOracle {
    struct Sensitive {
        let view: UIView
        let reason: String
    }

    /// Sensitive views by the contract, ignoring visibility (that is geometry's job).
    ///
    /// The root itself is not reported but its unmask state applies: the scanner walks it,
    /// and a plain `UIView` root is exactly what `unmaskedViewClasses = [UIView.self]` hits.
    static func sensitiveViews(in root: UIView, options: ReplayOptions, only generated: [UIView]? = nil)
        -> [Sensitive]
    {
        var result: [Sensitive] = []
        let rootUnmasked = root.mapleReplayMaskOverride == false
            || (root.mapleReplayMaskOverride == nil
                && options.unmaskedViewClasses.contains { ObjectIdentifier($0) == ObjectIdentifier(type(of: root)) })
        for subview in root.subviews {
            classify(subview, options: options, underUnmask: rootUnmasked, inherited: nil, into: &result)
        }
        // UIKit's private subviews (a text field's layout fragments) are judged by the
        // pixel fuzzer, which sees what they actually draw, not by their frames.
        guard let generated else { return result }
        let ids = Set(generated.map(ObjectIdentifier.init))
        return result.filter { ids.contains(ObjectIdentifier($0.view)) }
    }

    private static func classify(
        _ view: UIView, options: ReplayOptions, underUnmask: Bool, inherited: String?,
        into result: inout [Sensitive]
    ) {
        let override = view.mapleReplayMaskOverride
        let exactType = ObjectIdentifier(type(of: view))
        let classUnmasked = options.unmaskedViewClasses.contains { ObjectIdentifier($0) == exactType }
        // An instance-level mapleReplayMask() is documented as "whatever the masking
        // options say", so a class-level unmask does not override it.
        let explicitUnmask = override == false || (override == nil && classUnmasked)
        let secure = (view as? UITextInputTraits)?.isSecureTextEntry == true

        var reason: String?
        if secure {
            reason = "secure text entry"
        } else if let inherited {
            reason = "inside \(inherited)"
        } else if override == true {
            reason = underUnmask ? "mapleReplayMask() inside an unmasked ancestor" : "mapleReplayMask()"
        } else if !underUnmask, !explicitUnmask {
            if options.maskedViewClasses.contains(where: { view.isKind(of: $0) }) {
                reason = "maskedViewClasses"
            } else if view is UITextInput {
                reason = "text input"
            } else if options.maskAllText, view is UILabel {
                reason = "label (maskAllText)"
            } else if options.maskAllImages, let imageView = view as? UIImageView, !isChrome(imageView) {
                reason = "image (maskAllImages)"
            } else if options.maskAllText, view.subviews.isEmpty,
                      view is PrivacyFuzzDrawView || view is PrivacyFuzzKeyInputView {
                reason = "drawing leaf (maskAllText)"
            }
        }
        if let reason { result.append(Sensitive(view: view, reason: reason)) }

        let childInherited = inherited ?? reason.map { "a view masked for \($0)" }
        for subview in view.subviews {
            classify(subview, options: options, underUnmask: underUnmask || explicitUnmask,
                     inherited: childInherited, into: &result)
        }
    }

    /// "Small symbol or template chrome", restated from the contract.
    static func isChrome(_ imageView: UIImageView) -> Bool {
        guard let image = imageView.image else { return true }
        let small = imageView.bounds.width <= 44 && imageView.bounds.height <= 44
        return small && (image.isSymbolImage || image.renderingMode == .alwaysTemplate)
    }

    /// Whether `view` and every ancestor up to `root` is drawn at all.
    static func isVisible(_ view: UIView, root: UIView, presentation: Bool) -> Bool {
        var cursor: UIView? = view
        while let current = cursor, current !== root {
            if presentation {
                let layer = current.layer.presentation() ?? current.layer
                if layer.isHidden || layer.opacity <= 0.01 { return false }
            } else if current.isHidden || current.alpha <= 0.01 {
                return false
            }
            cursor = current.superview
        }
        return cursor === root
    }

    /// A point of `view`'s drawn region, in root space, that no rect covers. Points are
    /// sampled in the view's own space and kept only if every clipping ancestor and the
    /// root actually let them through.
    static func uncoveredPoint(
        of view: UIView, root: UIView, rects: [CGRect], presentation: Bool, tolerance: CGFloat = 0.5
    ) -> CGPoint? {
        let layer: CALayer
        let rootLayer: CALayer
        if presentation {
            guard let presented = view.layer.presentation() else { return nil }
            layer = presented
            rootLayer = root.layer.presentation() ?? root.layer
        } else {
            layer = view.layer
            rootLayer = root.layer
        }
        let bounds = layer.bounds.standardized
        guard bounds.width > 0, bounds.height > 0, bounds.width.isFinite, bounds.height.isFinite else { return nil }
        let box = layer.convert(bounds, to: rootLayer)
        guard !box.isNull, box.width.isFinite, box.height.isFinite, box.width >= 0.5, box.height >= 0.5 else {
            return nil
        }

        var clips: [CALayer] = []
        var cursor = view.superview
        while let current = cursor, current !== root {
            if current.clipsToBounds { clips.append(presentation ? (current.layer.presentation() ?? current.layer) : current.layer) }
            cursor = current.superview
        }

        let insetX = min(1, bounds.width * 0.1), insetY = min(1, bounds.height * 0.1)
        let steps = 6
        for i in 0...steps {
            for j in 0...steps {
                let local = CGPoint(
                    x: bounds.minX + insetX + (bounds.width - 2 * insetX) * CGFloat(i) / CGFloat(steps),
                    y: bounds.minY + insetY + (bounds.height - 2 * insetY) * CGFloat(j) / CGFloat(steps)
                )
                let point = layer.convert(local, to: rootLayer)
                guard point.x.isFinite, point.y.isFinite,
                      root.bounds.insetBy(dx: 0.5, dy: 0.5).contains(point) else { continue }
                let clippedAway = clips.contains { clip in
                    !clip.bounds.insetBy(dx: 0.5, dy: 0.5).contains(layer.convert(local, to: clip))
                }
                if clippedAway { continue }
                if !rects.contains(where: { $0.insetBy(dx: -tolerance, dy: -tolerance).contains(point) }) {
                    return point
                }
            }
        }
        return nil
    }

    /// Structural checks every scan must pass, whatever the tree.
    static func rectProblems(_ rects: [CGRect], root: UIView) -> [String] {
        rects.compactMap { rect in
            if !(rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite) {
                return "non-finite rect \(rect)"
            }
            if rect.width <= 0 || rect.height <= 0 { return "empty rect \(rect)" }
            if !root.bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect) { return "rect \(rect) outside root \(root.bounds)" }
            return nil
        }
    }
}

// MARK: - Windows

@MainActor
enum PrivacyFuzzWindow {
    static func make(size: CGSize = CGSize(width: 360, height: 640)) -> (UIWindow, UIView) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        let controller = UIViewController()
        controller.view.backgroundColor = UIColor(white: 0.9, alpha: 1)
        window.rootViewController = controller
        window.isHidden = false
        return (window, controller.view)
    }

    static func settle(_ seconds: TimeInterval = 0.15) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// How a fuzzer frame was obtained, so a run can say what it actually exercised.
    enum CapturePath: String { case viewCapture, drawHierarchyAfterUpdates, layerRender }

    /// The real capture when it works, else the same scan with an in-process draw.
    ///
    /// `ViewCapture` draws with `afterScreenUpdates: false`, which needs a frame the render
    /// server committed. A package test window has no scene, so that call fails ("Render
    /// server returned error"). The fallback keeps every other step of `ViewCapture`: scan
    /// first, then rasterise at the tier's scale into an opaque bitmap.
    static func capture(_ window: UIWindow, options: ReplayOptions) -> (PendingFrame, CapturePath)? {
        if let pending = ViewCapture.capture(window: window, options: options) { return (pending, .viewCapture) }
        let bounds = window.bounds
        let scan = RedactionScanner(options: options).scan(in: window)
        let format = UIGraphicsImageRendererFormat()
        format.scale = options.quality.effectiveScale(forPointSize: bounds.size)
        format.opaque = true
        var path = CapturePath.drawHierarchyAfterUpdates
        let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            if !window.drawHierarchy(in: bounds, afterScreenUpdates: true) {
                path = .layerRender
                window.layer.render(in: context.cgContext)
            }
        }
        return (PendingFrame(image: image, redactions: scan.rects, timestamp: Date(), sensitive: scan.sensitive), path)
    }

    static func tearDown(_ window: UIWindow) {
        window.isHidden = true
        window.rootViewController = nil
    }
}
