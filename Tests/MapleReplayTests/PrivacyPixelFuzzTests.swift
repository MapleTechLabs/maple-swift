import SwiftUI
import UIKit
import XCTest
@testable import MapleReplay

/// Pixel-level privacy fuzzing through the real pipeline: `ViewCapture.capture` then
/// `RedactionPainter.redactAndCompress`, decoded back from the JPEG.
///
/// Sensitive content is painted pure magenta and nothing else is, so any magenta pixel
/// in an output frame is sensitive content that survived. That needs no geometry at all,
/// which makes it independent of the rect oracle and of every scanner assumption.
@MainActor
final class PrivacyPixelFuzzTests: XCTestCase {
    private struct Tally {
        var captured = 0
        var skipped = 0
        /// Frames whose unredacted capture contained the sentinel: proof the check bites.
        var rawPositive = 0
        var paths: [PrivacyFuzzWindow.CapturePath: Int] = [:]
        var leaks: [String: Int] = [:]
    }

    func testRandomUIKitTreesLeakNoSensitivePixel() {
        var tally = Tally()
        for seed in PrivacyFuzzConfig.seeds(default: 5, slowDivisor: 20) {
            var rng = PrivacyFuzzRNG(seed: seed)
            let (window, content) = PrivacyFuzzWindow.make()
            defer { PrivacyFuzzWindow.tearDown(window) }
            let tree = PrivacyFuzzTreeGenerator.populate(content, rng: &rng, maxDepth: 5, maxViews: 40)
            let sensitive = PrivacyFuzzOracle.sensitiveViews(in: window, options: tree.options, only: tree.views)
            paint(tree, sensitive: Set(sensitive.map { ObjectIdentifier($0.view) }), rng: &rng)
            window.layoutIfNeeded()
            PrivacyFuzzWindow.settle()

            // A pixel leak the rect oracle also sees is a known scanner miss; one it does not
            // see (UIKit-internal drawing, glyph overflow, painter alignment) is new.
            let rects = RedactionScanner(options: tree.options).rects(in: window)
            let rectExplained = sensitive.contains { item in
                PrivacyFuzzOracle.isVisible(item.view, root: window, presentation: false)
                    && PrivacyFuzzOracle.uncoveredPoint(of: item.view, root: window, rects: rects, presentation: false) != nil
            }
            let imageOverflow = sensitive.contains { item in
                guard let imageView = item.view as? UIImageView, let image = imageView.image,
                      !imageView.clipsToBounds, ![.scaleToFill, .scaleAspectFit].contains(imageView.contentMode)
                else { return false }
                return image.size.width > imageView.bounds.width || image.size.height > imageView.bounds.height
            }
            let cause = rectExplained ? "also-a-rect-oracle-leak"
                : imageOverflow ? "image-drawn-outside-its-bounds" : "pixel-only"
            captureAtEveryTier(window, options: tree.options, seed: seed, cause: cause, tally: &tally) { point in
                Self.culprits(at: point, tree: tree, sensitive: sensitive, window: window)
            }
        }
        assertMeaningful(tally)
    }

    func testRandomSwiftUITreesLeakNoSensitivePixel() {
        var tally = Tally()
        for seed in PrivacyFuzzConfig.seeds(default: 4, slowDivisor: 25) {
            var rng = PrivacyFuzzRNG(seed: seed)
            var options = ReplayOptions()
            options.maskAllText = rng.chance(0.6)
            options.maskAllImages = rng.chance(0.6)
            var nodes = (0..<rng.int(2...6)).map { _ in
                SUINode.random(&rng, depth: 0, masked: false, unmasked: false, maskAllText: options.maskAllText)
            }
            // Always something that must stay hidden, so every iteration can fail.
            nodes.append(rng.chance(0.5) ? .unmask(.vstack([.secureField("hunter2"), .text("public", false)]))
                                         : .secureField("4111111111111111"))
            let description = nodes.map(\.description).joined(separator: "\n")

            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 640))
            defer { PrivacyFuzzWindow.tearDown(window) }
            window.rootViewController = UIHostingController(rootView: SUIScreen(nodes: nodes))
            window.isHidden = false
            window.layoutIfNeeded()
            PrivacyFuzzWindow.settle(0.3)
            window.layoutIfNeeded()
            PrivacyFuzzWindow.settle(0.1)

            captureAtEveryTier(window, options: options, seed: seed, cause: "swiftui", tally: &tally) { _ in
                "maskAllText=\(options.maskAllText) maskAllImages=\(options.maskAllImages)\ntree:\n\(description)"
            }
        }
        assertMeaningful(tally)
    }

    // MARK: - Pipeline

    /// Captures once per quality tier, since padding and resampling both scale with it.
    private func captureAtEveryTier(
        _ window: UIWindow, options: ReplayOptions, seed: UInt64, cause: String, tally: inout Tally,
        explain: (CGPoint) -> String
    ) {
        for quality in ReplayQuality.allCases {
            var options = options
            options.quality = quality
            guard let (pending, path) = PrivacyFuzzWindow.capture(window, options: options) else {
                tally.skipped += 1
                continue
            }
            tally.captured += 1
            tally.paths[path, default: 0] += 1
            if let raw = pending.image.cgImage.flatMap(PrivacyFuzzBitmap.init(cgImage:)),
               raw.sentinelPixels(limit: 1).count > 0 {
                tally.rawPositive += 1
            }
            guard let frame = RedactionPainter.redactAndCompress(pending, options: options),
                  let bitmap = PrivacyFuzzBitmap(jpeg: frame.jpeg) else {
                XCTFail("\(PrivacyFuzzConfig.describe(seed)) \(quality): redactAndCompress produced no decodable frame")
                continue
            }
            let leak = bitmap.sentinelPixels()
            guard leak.count > 0 else { continue }
            tally.leaks[cause, default: 0] += 1
            // First few per cause in full, so a known bug cannot bury a new one.
            guard tally.leaks[cause, default: 0] <= 3 else { continue }
            let scale = frame.size.width / window.bounds.width
            let points = leak.samples.map { CGPoint(x: $0.x / scale, y: $0.y / scale) }
            XCTFail("""
            [\(cause)] \(PrivacyFuzzConfig.describe(seed)) PRIVACY LEAK (pixels, \(quality)): \(leak.count) sensitive \
            pixel(s) survived redaction, first at window points \(points.map { "(\(Int($0.x)),\(Int($0.y)))" }).
            \(explain(points[0]))
            rects: \(pending.redactions.map(PrivacyFuzzTree.fmt))
            """)
        }
    }

    private func assertMeaningful(_ tally: Tally) {
        print("pixel fuzz: \(tally.captured) frames, \(tally.rawPositive) with sensitive pixels before redaction, "
              + "paths \(tally.paths.map { "\($0.key.rawValue)=\($0.value)" }), leaking frames by cause \(tally.leaks)")
        XCTAssertLessThanOrEqual(
            tally.skipped, tally.captured,
            "most captures returned nil (\(tally.skipped) skipped, \(tally.captured) captured): nothing was checked"
        )
        XCTAssertGreaterThan(tally.rawPositive, 0, "no unredacted frame ever contained sensitive pixels")
    }

    // MARK: - UIKit painting

    private func paint(_ tree: PrivacyFuzzTree, sensitive: Set<ObjectIdentifier>, rng: inout PrivacyFuzzRNG) {
        let magenta = PrivacyFuzzPalette.sentinel
        for view in tree.views {
            let hot = sensitive.contains(ObjectIdentifier(view))
            let safe = rng.pick(PrivacyFuzzPalette.safe)
            let color = hot ? magenta : safe
            view.backgroundColor = hot ? magenta : (rng.chance(0.5) ? safe : nil)
            view.tintColor = color
            switch view {
            case let label as UILabel: label.textColor = color
            case let field as UITextField: field.textColor = color
            case let textView as UITextView: textView.textColor = color
            case let draw as PrivacyFuzzDrawView: draw.fill = color
            case let input as PrivacyFuzzKeyInputView: input.fill = color
            case let imageView as UIImageView:
                if let image = imageView.image, !image.isSymbolImage {
                    imageView.image = PrivacyFuzzPalette.solidImage(color, size: image.size)
                        .withRenderingMode(image.renderingMode)
                }
            default: break
            }
        }
    }

    /// Sensitive views whose drawn box contains `point`, with why each is sensitive.
    private static func culprits(
        at point: CGPoint, tree: PrivacyFuzzTree, sensitive: [PrivacyFuzzOracle.Sensitive], window: UIWindow
    ) -> String {
        let hits = sensitive.filter { item in
            let box = (item.view.layer.presentation() ?? item.view.layer)
                .convert(item.view.bounds, to: window.layer.presentation() ?? window.layer)
            return box.insetBy(dx: -3, dy: -3).contains(point)
        }
        let body = hits.isEmpty
            ? "no generated sensitive view's box contains it (a UIKit-internal subview drew it)"
            : hits.map { "[\($0.reason)]\n\(tree.chain(to: $0.view))" }.joined(separator: "\n")
        return "options: \(tree.describeOptions())\nculprits:\n\(body)"
    }
}

// MARK: - SwiftUI trees

private indirect enum SUINode: CustomStringConvertible {
    case text(String, Bool)
    case textField(String)
    case secureField(String)
    case symbol(String, Bool)
    case block(CGFloat, CGFloat, Bool)
    case vstack([SUINode])
    case hstack([SUINode])
    case scroll([SUINode])
    case mask(SUINode)
    case unmask(SUINode)

    /// `masked` and `unmasked` are the enclosing modifiers; sensitivity is decided here so
    /// the colour a node is drawn in is the oracle.
    static func random(
        _ rng: inout PrivacyFuzzRNG, depth: Int, masked: Bool, unmasked: Bool, maskAllText: Bool
    ) -> SUINode {
        let leafOnly = depth >= 3
        switch rng.int(0...(leafOnly ? 4 : 9)) {
        case 0: return .text(rng.pick(["Ada Lovelace", "4111 1111", "MMWW"]), masked || (maskAllText && !unmasked))
        case 1: return .textField(rng.pick(["ada@example.com", "555-0100"]))
        case 2: return .secureField("hunter2")
        case 3: return .symbol(rng.pick(["person.fill", "creditcard.fill", "photo"]), masked)
        case 4: return .block(rng.cgFloat(10...200), rng.cgFloat(6...60), masked)
        case 5, 6:
            let children = (0..<rng.int(1...3)).map { _ in
                random(&rng, depth: depth + 1, masked: masked, unmasked: unmasked, maskAllText: maskAllText)
            }
            return rng.chance(0.5) ? .vstack(children) : .hstack(children)
        case 7:
            return .scroll((0..<rng.int(1...4)).map { _ in
                random(&rng, depth: depth + 1, masked: masked, unmasked: unmasked, maskAllText: maskAllText)
            })
        case 8: return .mask(random(&rng, depth: depth + 1, masked: true, unmasked: unmasked, maskAllText: maskAllText))
        default:
            return .unmask(random(&rng, depth: depth + 1, masked: masked, unmasked: true, maskAllText: maskAllText))
        }
    }

    var description: String { describe(0) }

    private func describe(_ depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        switch self {
        case .text(let s, let hot): return "\(pad)Text(\"\(s)\")\(hot ? " *" : "")"
        case .textField(let s): return "\(pad)TextField(\"\(s)\") *"
        case .secureField: return "\(pad)SecureField *"
        case .symbol(let name, let hot): return "\(pad)Image(systemName: \"\(name)\")\(hot ? " *" : "")"
        case .block(let w, let h, let hot): return "\(pad)Color \(Int(w))x\(Int(h))\(hot ? " *" : "")"
        case .vstack(let c): return "\(pad)VStack\n" + c.map { $0.describe(depth + 1) }.joined(separator: "\n")
        case .hstack(let c): return "\(pad)HStack\n" + c.map { $0.describe(depth + 1) }.joined(separator: "\n")
        case .scroll(let c): return "\(pad)ScrollView\n" + c.map { $0.describe(depth + 1) }.joined(separator: "\n")
        case .mask(let c): return "\(pad).mapleReplayMask()\n" + c.describe(depth + 1)
        case .unmask(let c): return "\(pad).mapleReplayUnmask()\n" + c.describe(depth + 1)
        }
    }
}

private struct SUIScreen: View {
    let nodes: [SUINode]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(nodes.enumerated()), id: \.offset) { SUIScreen.render($0.element) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.9))
    }

    private static let magenta = Color(red: 1, green: 0, blue: 1)
    private static let safe = Color(red: 0.1, green: 0.6, blue: 0.2)

    static func render(_ node: SUINode) -> AnyView {
        switch node {
        case .text(let s, let hot):
            return AnyView(Text(s).font(.system(size: 22, weight: .black)).foregroundColor(hot ? magenta : safe))
        case .textField(let s):
            return AnyView(TextField("", text: .constant(s)).font(.system(size: 22, weight: .black))
                .foregroundColor(magenta).frame(width: 220, height: 34))
        case .secureField(let s):
            return AnyView(SecureField("", text: .constant(s)).font(.system(size: 22, weight: .black))
                .foregroundColor(magenta).frame(width: 220, height: 34))
        case .symbol(let name, let hot):
            return AnyView(Image(systemName: name).resizable().frame(width: 56, height: 48)
                .foregroundColor(hot ? magenta : safe))
        case .block(let w, let h, let hot):
            return AnyView((hot ? magenta : safe).frame(width: w, height: h))
        case .vstack(let children):
            return AnyView(VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(children.enumerated()), id: \.offset) { render($0.element) }
            })
        case .hstack(let children):
            return AnyView(HStack(spacing: 4) {
                ForEach(Array(children.enumerated()), id: \.offset) { render($0.element) }
            })
        case .scroll(let children):
            return AnyView(ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(children.enumerated()), id: \.offset) { render($0.element) }
                }
            }.frame(height: 140))
        case .mask(let child): return AnyView(render(child).mapleReplayMask())
        case .unmask(let child): return AnyView(render(child).mapleReplayUnmask())
        }
    }
}
