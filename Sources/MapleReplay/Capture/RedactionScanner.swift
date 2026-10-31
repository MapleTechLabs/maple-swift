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
///
/// The price of that asymmetry is over-masking, and the one reduction that is free of it
/// is clipping: a rect is trimmed to the region its view was allowed to draw in. Trimming
/// never uncovers anything — the pixels removed were never the view's to paint — and
/// without it a half-scrolled row masks the header above its table.
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
        scan(in: root, excluding: excluding).rects
    }

    /// One scan's output.
    struct Result: Equatable {
        /// Everything to paint over.
        var rects: [CGRect]
        /// The subset masked no matter what (typed input, explicit masks, always-masked
        /// classes), where a touch's position must not be recorded either.
        var sensitive: [CGRect]
    }

    /// A rect plus whether an unmask region is allowed to drop it.
    struct Redaction {
        var rect: CGRect
        var forced: Bool
        /// Produced inside a nested view controller's screen, which unmask regions of the
        /// screens around it must not reach.
        var sealed = false
    }

    private struct Walk {
        var redactions: [Redaction] = []
        var unmaskRegions: [CGRect] = []
    }

    func scan(in root: UIView, excluding: UIView? = nil) -> Result {
        var walk = Walk()
        // The capture is the root's bounds, so that is the outermost clip. Anything
        // outside it was never rasterised and a rect over it can only mask other content.
        scan(
            root, root: root, excluding: excluding, clip: root.bounds,
            animating: false, rules: .all, into: &walk
        )
        // Regions no view controller scoped are applied to the whole window.
        Self.applyUnmask(walk.unmaskRegions, to: &walk.redactions, from: 0)
        let kept = walk.redactions
        return Result(
            rects: merge(kept.map(\.rect)),
            sensitive: merge(kept.filter(\.forced).map(\.rect))
        )
    }

    /// Which views produced which rects, for diagnosing over-masking.
    ///
    /// Over-masking is this design's characteristic failure: one unrecognised full-screen
    /// leaf redacts everything and the replay becomes a solid block. That is safe but
    /// useless, and it is invisible in the output — you see a mask and cannot tell whether
    /// it came from the label you expected or from its grandparent.
    func debugRects(in root: UIView, excluding: UIView? = nil) -> [(name: String, rect: CGRect)] {
        var result: [(String, CGRect)] = []
        debugScan(root, root: root, excluding: excluding, clip: root.bounds, into: &result)
        return result.map { (name: $0.0, rect: $0.1) }
    }

    private func debugScan(
        _ view: UIView, root: UIView, excluding: UIView?, clip: CGRect,
        into result: inout [(String, CGRect)]
    ) {
        guard view !== excluding, !(view is MaskingPreviewView) else { return }
        guard !view.isHidden, view.alpha > 0.01 else { return }
        if !Self.isSafetyMasked(view), isExplicitlyUnmasked(view) { return }

        guard let visible = clipped(view.convert(view.bounds, to: root), to: clip) else { return }

        if let marker = view as? ReplayMarkerView {
            if marker.kind == .mask { result.append(("mapleReplayMask()", visible)) }
            return
        }

        if shouldMask(view) {
            result.append((NSStringFromClass(type(of: view)), visible))
            return
        }
        // Layer-level content is attributed to its owning view, so a diagnostic dump
        // accounts for every rect the real scan produces.
        let subtreeClip = view.clipsToBounds ? visible : clip
        let owner = NSStringFromClass(type(of: view))
        for rect in contentLayerRects(of: view, root: root, clip: subtreeClip) {
            result.append(("\(owner)→layer", rect))
        }
        for subview in view.subviews {
            debugScan(subview, root: root, excluding: excluding, clip: subtreeClip, into: &result)
        }
    }

    /// How much of the rule set applies beneath a view.
    private enum Rules {
        /// Everything.
        case all
        /// Inside an explicit unmask: only the rules no opt-out reaches (typed input,
        /// explicit masks, masked classes). The automatic text and image heuristics are
        /// what an unmask turns off.
        case forcedOnly
        /// Inside a masked view that does not clip: every visible descendant is masked,
        /// because UIKit draws it even where it hangs outside the parent's mask.
        case inherited(forced: Bool)
    }

    private func scan(
        _ view: UIView, root: UIView, excluding: UIView?, clip: CGRect,
        animating ancestorAnimating: Bool, rules: Rules, into walk: inout Walk
    ) {
        guard view !== excluding else { return }
        // The debug overlay is an unrecognised leaf, so the unknown-leaf rule would have
        // it mask the entire screen the moment it is switched on.
        guard !(view is MaskingPreviewView) else { return }
        guard !view.isHidden else { return }

        // Sticky down the tree: a pushed controller animates its root view's layer, and
        // every descendant is drawn wherever that animation has carried it.
        let animating = ancestorAnimating || !(view.layer.animationKeys()?.isEmpty ?? true)

        // A fade-out sets the stored alpha to its end value at once while the screen
        // keeps showing the view for the whole animation, so mid-animation the drawn
        // opacity is the one that counts.
        if view.alpha <= 0.01 {
            guard animating, (view.layer.presentation()?.opacity ?? 0) > 0.01 else { return }
        }

        // `clip` is the intersection of every clipping ancestor's bounds: the region this
        // view can actually appear in. A rect outside it covers content the view does not
        // draw. The view itself being off-frame or empty does not end the walk, because a
        // view that does not clip still draws children that land on frame.
        let modelRect = clipped(view.convert(view.bounds, to: root), to: clip)
        // Mid-animation the frame on screen is the presentation tree's, while the view
        // tree already holds the end state. Masking both places is the only answer that
        // covers the drawn frame without trusting either clock.
        let presentationRect = animating ? presentationRect(of: view.layer, in: root) : nil
        let ownRects = [modelRect, presentationRect].compactMap { $0 }

        func add(forced: Bool, extra: [CGRect] = []) {
            for rect in ownRects + extra {
                walk.redactions.append(Redaction(rect: rect, forced: forced))
            }
        }
        func descend(_ rules: Rules) {
            scanSubviews(of: view, root: root, excluding: excluding, clip: clip, visible: modelRect,
                         animating: animating, rules: rules, into: &walk)
        }
        /// Mask this view, and its descendants too when they can draw outside it.
        func mask(forced: Bool) {
            add(forced: forced, extra: overflowRects(of: view, root: root, clip: clip))
            guard !view.clipsToBounds else { return }
            // Drawing layers can sit outside a non-clipping view's bounds too.
            for rect in contentLayerRects(of: view, root: root, clip: clip, animating: animating) {
                walk.redactions.append(Redaction(rect: rect, forced: forced))
            }
            descend(.inherited(forced: forced))
        }

        if let marker = view as? ReplayMarkerView {
            switch marker.kind {
            case .mask: add(forced: true)
            case .unmask: walk.unmaskRegions.append(contentsOf: ownRects)
            }
            return
        }

        // An unmask region only reaches content of the screen it is on. Bounded at each
        // view controller's root view, so an alert, a sheet or the incoming screen of a
        // push drawn over an unmasked card keeps its own masks.
        let scope = view.next is UIViewController ? (walk.redactions.count, walk.unmaskRegions.count) : nil
        defer {
            if let (redactionStart, regionStart) = scope {
                Self.applyUnmask(Array(walk.unmaskRegions[regionStart...]), to: &walk.redactions, from: redactionStart)
                walk.unmaskRegions.removeSubrange(regionStart...)
                for index in redactionStart..<walk.redactions.count { walk.redactions[index].sealed = true }
            }
        }

        if case .inherited(let forced) = rules {
            mask(forced: forced || isForcedByRule(view))
            return
        }

        // Typed input, secure entry and an explicit per-view mask come before any opt-out:
        // no unmask, class list or region reaches them.
        if Self.isSafetyMasked(view) {
            mask(forced: true)
            return
        }

        if case .all = rules, isExplicitlyUnmasked(view) {
            descend(.forcedOnly)
            return
        }

        if isMember(view, ofAny: options.maskedViewClasses) || isMember(view, ofAny: Self.alwaysMaskedTypes) {
            mask(forced: true)
            return
        }

        guard case .all = rules else {
            descend(rules)
            return
        }

        if shouldMaskByContent(view) {
            mask(forced: false)
            return
        }

        // Content this view draws into its *own* layers, independent of its subviews.
        //
        // This is the case a leaf-only rule misses entirely. Since iOS 26, SwiftUI draws
        // text and shapes as `CGDrawingLayer` sublayers of a host view that also has child
        // views, so the host is not a leaf, and every string it rendered would otherwise
        // never be examined. Masking the host wholesale would redact the screen; masking
        // its drawing layers individually is precise.
        //
        // Gated on `maskAllText` for the same reason as the unknown-leaf rule: a
        // `CGDrawingLayer` carries no type information, so we cannot tell a rendered
        // string from a rendered image and must treat the whole category as text.
        // SwiftUI-drawn images are therefore covered by `maskAllText`, not by
        // `maskAllImages`, which only reaches `UIImageView`.
        if options.maskAllText {
            let subtreeClip = view.clipsToBounds ? (modelRect ?? clip) : clip
            for rect in contentLayerRects(of: view, root: root, clip: subtreeClip, animating: animating) {
                walk.redactions.append(Redaction(rect: rect, forced: false))
            }
        }

        descend(rules)
    }

    /// Forced by an option or a fixed rule, short of the safety rules: masked classes and
    /// the always-masked types. An unmask region cannot drop these.
    private func isForcedByRule(_ view: UIView) -> Bool {
        Self.isSafetyMasked(view)
            || isMember(view, ofAny: options.maskedViewClasses)
            || isMember(view, ofAny: Self.alwaysMaskedTypes)
    }

    /// Drop non-forced redactions from `start` on that lie wholly inside a region. Never
    /// what a region only touches.
    private static func applyUnmask(_ regions: [CGRect], to redactions: inout [Redaction], from start: Int) {
        guard !regions.isEmpty, start < redactions.count else { return }
        let scoped = redactions[start...].filter { redaction in
            redaction.forced || redaction.sealed || !regions.contains { $0.contains(redaction.rect) }
        }
        redactions.replaceSubrange(start..., with: scoped)
    }

    /// Masked whatever the options or any opt-out say.
    ///
    /// `UIKeyInput` rather than `UITextInput`: a custom PIN pad typically adopts only
    /// the smaller protocol, and anything that accepts typed characters is typed input.
    private static func isSafetyMasked(_ view: UIView) -> Bool {
        if view.mapleReplayMaskOverride == true { return true }
        if view is UIKeyInput { return true }
        if let traits = view as? UITextInputTraits, traits.isSecureTextEntry == true { return true }
        return false
    }

    /// Where a view draws beyond its own bounds, which a mask taken from its frame misses.
    ///
    /// Today that is an image view that does not clip: `.scaleAspectFill`, `.center` and
    /// the edge modes paint the image wherever its size puts it.
    private func overflowRects(of view: UIView, root: UIView, clip: CGRect) -> [CGRect] {
        guard !view.clipsToBounds, let imageView = view as? UIImageView,
              let image = imageView.image else { return [] }
        let drawn = Self.imageRect(image.size, in: imageView.bounds, mode: imageView.contentMode)
        guard !imageView.bounds.contains(drawn) else { return [] }
        return [clipped(imageView.convert(drawn, to: root), to: clip)].compactMap { $0 }
    }

    /// Where UIKit draws an image of `size` inside `bounds` for `mode`.
    static func imageRect(_ size: CGSize, in bounds: CGRect, mode: UIView.ContentMode) -> CGRect {
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return bounds }
        switch mode {
        case .scaleToFill, .redraw:
            return bounds
        case .scaleAspectFit, .scaleAspectFill:
            let ratio = mode == .scaleAspectFit
                ? min(bounds.width / size.width, bounds.height / size.height)
                : max(bounds.width / size.width, bounds.height / size.height)
            let fitted = CGSize(width: size.width * ratio, height: size.height * ratio)
            return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                          width: fitted.width, height: fitted.height)
        default:
            let x: CGFloat
            switch mode {
            case .left, .topLeft, .bottomLeft: x = bounds.minX
            case .right, .topRight, .bottomRight: x = bounds.maxX - size.width
            default: x = bounds.midX - size.width / 2
            }
            let y: CGFloat
            switch mode {
            case .top, .topLeft, .topRight: y = bounds.minY
            case .bottom, .bottomLeft, .bottomRight: y = bounds.maxY - size.height
            default: y = bounds.midY - size.height / 2
            }
            return CGRect(origin: CGPoint(x: x, y: y), size: size)
        }
    }

    private func scanSubviews(
        of view: UIView, root: UIView, excluding: UIView?, clip: CGRect, visible: CGRect?,
        animating: Bool, rules: Rules, into walk: inout Walk
    ) {
        // A view that clips narrows the clip for everything beneath it. A view that does
        // not clip passes the ancestors' clip through unchanged, because UIKit draws
        // subviews outside a non-clipping parent's bounds. A clipping view whose model
        // rect is off-frame but is mid-animation keeps the outer clip: its presentation
        // may be on frame, and narrowing to nothing would let its children through.
        let subtreeClip: CGRect
        if view.clipsToBounds, !animating {
            guard let visible else { return }
            subtreeClip = visible
        } else {
            subtreeClip = clip
        }
        for subview in view.subviews {
            scan(subview, root: root, excluding: excluding, clip: subtreeClip,
                 animating: animating, rules: rules, into: &walk)
        }
    }

    /// Where `layer` is drawn right now, in `root`'s space, clipped to the captured frame.
    ///
    /// Clipped to the root rather than to the model-tree clip: during a transition the
    /// clipping ancestors are moving too, and a model clip would cut away exactly the
    /// part of the presentation rect that is on screen.
    private func presentationRect(of layer: CALayer, in root: UIView) -> CGRect? {
        guard let rootLayer = root.layer.presentation() ?? Optional(root.layer),
              let presented = layer.presentation() else { return nil }
        return clipped(presented.convert(presented.bounds, to: rootLayer), to: root.bounds)
    }

    /// `rect` reduced to the part of it that is inside `clip`, or nil if none of it is.
    ///
    /// Every rect this scanner emits goes through here. Clipping can only ever shrink or
    /// drop a rect, never move or grow one, so it cannot uncover anything: a pixel removed
    /// from a mask is a pixel the masked view was not allowed to draw on.
    private func clipped(_ rect: CGRect, to clip: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite else { return nil }
        let visible = rect.intersection(clip)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return visible
    }

    /// Whether this view is named in `unmaskedViewClasses`, matched by exact type.
    ///
    /// Exact type, not `isKind(of:)`, and the asymmetry with `maskedViewClasses` is the
    /// point. Masking a superclass over-masks its subclasses, which is safe. *Unmasking* a
    /// superclass silently unmasks every subclass of it in the app — put `UILabel` in this
    /// list to expose one price tag and the account-number label two screens over is
    /// exposed with it, without ever being named. An escape hatch has to be narrow enough
    /// that using it is a decision about the class you actually wrote down.
    private func isExplicitlyUnmasked(_ view: UIView) -> Bool {
        if view.mapleReplayMaskOverride == false { return true }
        guard !options.unmaskedViewClasses.isEmpty else { return false }
        let viewType = ObjectIdentifier(type(of: view))
        return options.unmaskedViewClasses.contains { ObjectIdentifier($0) == viewType }
    }

    /// Rects of content-bearing layers owned by `view` itself.
    ///
    /// Subviews' layers are excluded — they are reached by the view walk, which can apply
    /// the full masking rules to them. Only layers with no owning view are handled here.
    private func contentLayerRects(
        of view: UIView, root: UIView, clip: CGRect, animating: Bool = false
    ) -> [CGRect] {
        guard let sublayers = view.layer.sublayers, !sublayers.isEmpty else { return [] }
        // Subviews' layers are sublayers of their superview's layer. Skip them at any
        // depth — the view walk reaches them and can apply the full masking rules;
        // handling them here too would double-count and bypass those rules.
        let subviewLayers = Set(view.subviews.map { ObjectIdentifier($0.layer) })

        var result: [CGRect] = []
        for layer in sublayers {
            collectContentLayers(
                layer, root: root, skipping: subviewLayers, clip: clip,
                animating: animating, into: &result
            )
        }
        return result
    }

    private func collectContentLayers(
        _ layer: CALayer,
        root: UIView,
        skipping subviewLayers: Set<ObjectIdentifier>,
        clip: CGRect,
        animating: Bool = false,
        into result: inout [CGRect]
    ) {
        guard !subviewLayers.contains(ObjectIdentifier(layer)) else { return }
        guard !layer.isHidden, layer.opacity > 0.01 else { return }

        let name = String(describing: type(of: layer))
        if Self.decorativeLayerTypes.contains(name) { return }

        let sublayers = layer.sublayers ?? []

        // The layer-tree counterpart of `clipsToBounds`, and it is not redundant with it:
        // SwiftUI's drawing layers are routinely laid out beyond the bounds of the layer
        // that masks them, so a rect taken from one alone can spill well outside the view.
        let bounds = layer.convert(layer.bounds, to: root.layer)
        let subtreeClip = layer.masksToBounds ? bounds.intersection(clip) : clip

        // A layer with children and no bitmap of its own is a compositing container —
        // UIKit's `_UIMultiLayer`, SwiftUI's grouping layers. Descend into it rather than
        // masking it: a container's bounds span everything beneath it, so treating one as
        // content redacts the whole screen. Observed exactly that from
        // `UITransitionView`'s `_UIMultiLayer`.
        if layer.contents == nil, !sublayers.isEmpty {
            for sublayer in sublayers {
                collectContentLayers(
                    sublayer, root: root, skipping: subviewLayers, clip: animating ? clip : subtreeClip,
                    animating: animating, into: &result
                )
            }
            return
        }

        guard isContentBearing(layer) else { return }
        if let visible = clipped(bounds, to: clip) { result.append(visible) }
        if animating, let presented = presentationRect(of: layer, in: root) { result.append(presented) }
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
        maskDecision(view) != nil
    }

    /// Nil when the view is not masked; otherwise whether the mask is forced.
    private func maskDecision(_ view: UIView) -> Bool? {
        if Self.isSafetyMasked(view) { return true }
        if isMember(view, ofAny: options.maskedViewClasses) { return true }
        if isMember(view, ofAny: Self.alwaysMaskedTypes) { return true }
        return shouldMaskByContent(view) ? false : nil
    }

    private func shouldMaskByContent(_ view: UIView) -> Bool {

        // Anything the user can type into, identified structurally.
        //
        // `UITextInput` is the protocol UIKit requires of every view that accepts text
        // entry, so conformance — not a class name — is what identifies one. That matters
        // for SwiftUI, whose `TextField` and `SecureField` are backed by private views
        // (`SwiftUI.TextEditorTextView` and friends) whose names change between releases.
        // Conformance is part of the platform contract and doesn't.
        //
        // Unconditional, above every option: typed input is the category Apple's
        // enforcement history is actually about — the 2019 session-replay removals turned
        // on card and passport numbers leaking out of form fields.
        if view is UIKeyInput { return true }

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
        //
        // Gated on `maskAllText`, because "unidentifiable drawn content" is overwhelmingly
        // text and this rule is what the option is really controlling. Ungated, it made
        // `maskAllText` and `maskAllImages` inert on SwiftUI: turning both off changed
        // nothing, because this rule masked everything anyway.
        if options.maskAllText, view.subviews.isEmpty, drawsOwnContent(view) { return true }

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

    /// Class membership in the *masking* direction, subclasses included.
    ///
    /// `isKind(of:)` is right here and wrong for unmasking — see `isExplicitlyUnmasked`.
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
