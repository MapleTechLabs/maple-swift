import Foundation
import UIKit

/// Walks the view hierarchy to locate regions that must be painted over before a frame
/// is retained.
///
/// This is the *only* reason we touch the view tree. We never reconstruct the UI from it —
/// that's the wireframe approach, and it's what forces SDKs into maintaining tables of
/// private SwiftUI class names that churn every iOS release.
///
/// Because we only need rects, we can invert the rule that makes wireframes brittle:
///
///   **A leaf view we cannot positively identify as safe is masked.**
///
/// When Apple renames a SwiftUI internal, a wireframe recorder renders a blank box where
/// your UI was. We render a redaction rect over content that may not have needed one —
/// degraded, but never leaking. That asymmetry is the whole reason this design survives
/// iOS releases without maintenance.
struct RedactionScanner {
    let options: ReplayOptions

    /// Classes whose contents are inherently sensitive regardless of configuration.
    private static let alwaysMaskedTypes: [AnyClass] = {
        var types: [AnyClass] = [UITextView.self, UITextField.self]
        // WKWebView renders arbitrary remote content we cannot reason about.
        if let webView = NSClassFromString("WKWebView") { types.append(webView) }
        return types
    }()

    /// Container classes that only lay out other views and draw nothing themselves.
    /// A leaf of one of these types has no content to leak.
    private static let inertContainerTypes: [AnyClass] = [
        UIScrollView.self, UIStackView.self, UITableView.self,
        UICollectionView.self, UIProgressView.self, UIActivityIndicatorView.self,
    ]

    /// Compute redaction rects in `root`'s coordinate space.
    ///
    /// `excluding` skips a subtree entirely. Used by the masking preview overlay, which
    /// lives inside the window it is scanning and would otherwise mask itself — and,
    /// being an unrecognised leaf, would mask the entire screen.
    func rects(in root: UIView, excluding: UIView? = nil) -> [CGRect] {
        var result: [CGRect] = []
        scan(root, root: root, excluding: excluding, into: &result)
        return merge(result)
    }

    /// Which views produced which rects, for diagnosing over-masking.
    ///
    /// Over-masking is this design's characteristic failure: one unrecognised full-screen
    /// leaf redacts everything and the replay becomes a solid block. That is safe but
    /// useless, and it is invisible in the output — you see a mask and cannot tell whether
    /// it came from the label you expected or from its grandparent.
    func debugRects(in root: UIView, excluding: UIView? = nil) -> [(name: String, rect: CGRect)] {
        var result: [(String, CGRect)] = []
        debugScan(root, root: root, excluding: excluding, into: &result)
        return result.map { (name: $0.0, rect: $0.1) }
    }

    private func debugScan(
        _ view: UIView, root: UIView, excluding: UIView?, into result: inout [(String, CGRect)]
    ) {
        guard view !== excluding, !(view is MaskingPreviewView) else { return }
        guard !view.isHidden, view.alpha > 0.01 else { return }
        if isMember(view, ofAny: options.unmaskedViewClasses) { return }

        let visible = view.convert(view.bounds, to: root)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

        if shouldMask(view) {
            result.append((NSStringFromClass(type(of: view)), visible))
            return
        }
        // Layer-level content is attributed to its owning view, so a diagnostic dump
        // accounts for every rect the real scan produces.
        let owner = NSStringFromClass(type(of: view))
        for rect in contentLayerRects(of: view, root: root) {
            result.append(("\(owner)→layer", rect))
        }
        for subview in view.subviews {
            debugScan(subview, root: root, excluding: excluding, into: &result)
        }
    }

    private func scan(_ view: UIView, root: UIView, excluding: UIView?, into result: inout [CGRect]) {
        guard view !== excluding else { return }
        // The debug overlay is an unrecognised leaf, so the unknown-leaf rule would have
        // it mask the entire screen the moment it is switched on.
        guard !(view is MaskingPreviewView) else { return }
        guard !view.isHidden, view.alpha > 0.01 else { return }

        // An explicit unmask opt-out wins over everything, including the unknown-leaf rule.
        // This is the single escape hatch, and it is deliberately the only one.
        if isMember(view, ofAny: options.unmaskedViewClasses) { return }

        let visible = view.convert(view.bounds, to: root)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return }

        if shouldMask(view) {
            result.append(visible)
            // Masking the parent covers every descendant; no need to walk further.
            return
        }

        // Content this view draws into its *own* layers, independent of its subviews.
        //
        // This is the case a leaf-only rule misses entirely. Since iOS 26, SwiftUI draws
        // text and shapes as `CGDrawingLayer` sublayers of a host view that also has
        // child views — so the host is not a leaf, and every string it rendered would
        // otherwise never be examined. Masking the host wholesale would redact the screen;
        // masking its drawing layers individually is precise.
        result.append(contentsOf: contentLayerRects(of: view, root: root))

        for subview in view.subviews {
            scan(subview, root: root, excluding: excluding, into: &result)
        }
    }

    /// Rects of content-bearing layers owned by `view` itself.
    ///
    /// Subviews' layers are excluded — they are reached by the view walk, which can apply
    /// the full masking rules to them. Only layers with no owning view are handled here.
    private func contentLayerRects(of view: UIView, root: UIView) -> [CGRect] {
        guard let sublayers = view.layer.sublayers, !sublayers.isEmpty else { return [] }
        // Subviews' layers are sublayers of their superview's layer. Skip them at any
        // depth — the view walk reaches them and can apply the full masking rules;
        // handling them here too would double-count and bypass those rules.
        let subviewLayers = Set(view.subviews.map { ObjectIdentifier($0.layer) })

        var result: [CGRect] = []
        for layer in sublayers {
            collectContentLayers(layer, root: root, skipping: subviewLayers, into: &result)
        }
        return result
    }

    private func collectContentLayers(
        _ layer: CALayer,
        root: UIView,
        skipping subviewLayers: Set<ObjectIdentifier>,
        into result: inout [CGRect]
    ) {
        guard !subviewLayers.contains(ObjectIdentifier(layer)) else { return }
        guard !layer.isHidden, layer.opacity > 0.01 else { return }

        let name = String(describing: type(of: layer))
        if Self.decorativeLayerTypes.contains(name) { return }

        let sublayers = layer.sublayers ?? []

        // A layer with children and no bitmap of its own is a compositing container —
        // UIKit's `_UIMultiLayer`, SwiftUI's grouping layers. Descend into it rather than
        // masking it: a container's bounds span everything beneath it, so treating one as
        // content redacts the whole screen. Observed exactly that from
        // `UITransitionView`'s `_UIMultiLayer`.
        if layer.contents == nil, !sublayers.isEmpty {
            for sublayer in sublayers {
                collectContentLayers(sublayer, root: root, skipping: subviewLayers, into: &result)
            }
            return
        }

        if isContentBearing(layer) {
            let rect = layer.convert(layer.bounds, to: root.layer)
            if rect.width > 0, rect.height > 0 { result.append(rect) }
        }
    }

    /// Layer classes that render only decoration, never information.
    ///
    /// A backdrop layer blurs what is already on screen behind it, and a gradient paints
    /// a fill — neither introduces content that isn't redacted elsewhere. Everything else
    /// unrecognised is treated as content, keeping the same fail-safe asymmetry as the
    /// view walk.
    private static let decorativeLayerTypes: Set<String> = [
        "CABackdropLayer", "CAGradientLayer",
    ]

    private func isContentBearing(_ layer: CALayer) -> Bool {
        if layer.contents != nil { return true }
        // A plain CALayer draws only its background colour; anything else is a
        // specialised drawing layer (CGDrawingLayer, CATextLayer, _UILabelLayer, …).
        return type(of: layer) != CALayer.self
    }

    private func shouldMask(_ view: UIView) -> Bool {
        if isMember(view, ofAny: options.maskedViewClasses) { return true }
        if isMember(view, ofAny: Self.alwaysMaskedTypes) { return true }

        if options.maskAllText {
            if view is UILabel { return true }
            // A secure field is masked above via UITextField, but a custom conformer isn't.
            if let input = view as? UITextInputTraits, input.isSecureTextEntry == true { return true }
        }

        if options.maskAllImages, let imageView = view as? UIImageView {
            // Small symbol images are chrome (chevrons, checkmarks), not user content.
            // Masking them makes the replay unreadable for no privacy gain.
            return !isLikelyChrome(imageView)
        }

        // The unknown-leaf rule. Anything that draws its own content and has no children
        // is unidentifiable — most SwiftUI text and images land here, under private class
        // names we deliberately do not enumerate.
        if view.subviews.isEmpty, drawsOwnContent(view) { return true }

        return false
    }

    /// Does this leaf render content of its own, as opposed to a spacer or a flat
    /// background fill?
    ///
    /// This is answered **structurally**, never by class name. Name matching is the trap:
    /// it works until Apple renames something, and the whole point of this design is to
    /// survive that. A view renders real content if and only if one of these holds:
    ///
    ///  - its layer has bitmap `contents` (images, snapshots, rendered text)
    ///  - it has a sublayer that is not a plain empty `CALayer` (this is how iOS 26's
    ///    SwiftUI engine draws text and shapes — as `CGDrawingLayer` sublayers rather
    ///    than child views)
    ///  - its class overrides `draw(_:)`, i.e. it does custom Core Graphics drawing
    ///
    /// A view that satisfies none of these can only paint `backgroundColor`, which
    /// carries no information. That is exactly what UIKit's full-screen decoration and
    /// background views are, and treating them as content masks the entire screen.
    private func drawsOwnContent(_ view: UIView) -> Bool {
        if isMember(view, ofAny: Self.inertContainerTypes) { return false }
        if type(of: view) == UIView.self { return false }

        if view.layer.contents != nil { return true }

        // Sublayer content is handled separately and more precisely by
        // `contentLayerRects`, which masks each drawing layer rather than the whole view.
        return Self.overridesDraw(type(of: view))
    }

    private static let drawOverrideCache = NSCache<NSString, NSNumber>()

    /// Whether `cls` provides its own `draw(_:)` rather than inheriting UIView's no-op.
    ///
    /// Cached: this runs for every leaf on every captured frame, and an `objc` IMP lookup
    /// per view per frame is real cost at 1 fps on a dense screen.
    private static func overridesDraw(_ cls: AnyClass) -> Bool {
        let key = NSStringFromClass(cls) as NSString
        if let cached = drawOverrideCache.object(forKey: key) { return cached.boolValue }

        let selector = #selector(UIView.draw(_:))
        let base = class_getMethodImplementation(UIView.self, selector)
        let implementation = class_getMethodImplementation(cls, selector)
        let overrides = implementation != base

        drawOverrideCache.setObject(NSNumber(value: overrides), forKey: key)
        return overrides
    }

    /// Chrome is small *and* vector — a chevron, a checkmark, a tab icon.
    ///
    /// Both halves are load-bearing, and the order matters. Size alone would let a 40pt
    /// avatar thumbnail through, and that is exactly the PII this is meant to catch.
    /// Symbol-ness alone would let a full-bleed SF Symbol hero image through. Only the
    /// conjunction is safe, and anything content-sized is masked regardless of what
    /// it draws.
    private func isLikelyChrome(_ imageView: UIImageView) -> Bool {
        guard let image = imageView.image else { return true }

        let bounds = imageView.bounds
        let isSmall = bounds.width <= 44 && bounds.height <= 44
        guard isSmall else { return false }

        return image.isSymbolImage || image.renderingMode == .alwaysTemplate
    }

    private func isMember(_ view: UIView, ofAny classes: [AnyClass]) -> Bool {
        classes.contains { view.isKind(of: $0) }
    }

    /// Drop rects fully contained within another. Nothing is ever unioned.
    ///
    /// Unioning merely-intersecting rects looks like a harmless optimisation and is not:
    /// each union grows the rect, the grown rect then intersects more neighbours, and a
    /// column of slightly-overlapping rows collapses into one full-screen mask. That was
    /// observed here — 100% coverage from a single rect. Containment can only ever
    /// shrink the set, so it cannot run away.
    private func merge(_ rects: [CGRect]) -> [CGRect] {
        guard rects.count > 1 else { return rects }
        // Largest first, so a container is seen before the rects it swallows.
        let sorted = rects.sorted { $0.width * $0.height > $1.width * $1.height }
        var kept: [CGRect] = []
        for rect in sorted where !kept.contains(where: { $0.contains(rect) }) {
            kept.append(rect)
        }
        return kept
    }
}
