import Foundation
import UIKit

/// A screen snapshot plus the redaction rects computed for it, before painting.
///
/// This pair only ever exists in memory on the main thread, for the moment between
/// snapshot and redaction. Nothing unredacted is written to disk or retained in the
/// ring buffer.
struct PendingFrame {
    let image: UIImage
    let redactions: [CGRect]
    let timestamp: Date
}

enum ViewCapture {
    /// Snapshot the active window and compute its redaction rects.
    ///
    /// Must run on the main thread — both `drawHierarchy` and view-tree traversal are
    /// main-thread-only.
    @MainActor
    static func capture(options: ReplayOptions) -> PendingFrame? {
        guard let window = activeWindow() else { return nil }
        let bounds = window.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        // Scan *before* drawing, and do nothing in between that could move a view.
        //
        // `capture` runs as its own main-thread turn — the recorder's timer hops here
        // via `DispatchQueue.main.async` — so the previous run loop's CATransaction has
        // already committed. The tree walked here and the frame the render server holds
        // are therefore the same layout state, which is what lets the draw below be
        // cheap. Nothing between this line and the draw may force a layout pass.
        //
        // In particular, *not* `window.layoutIfNeeded()`, which used to run here. It
        // applies pending layout to the view tree without committing it to the render
        // server, which is exactly how the two fall out of step — see the draw below.
        let redactions = RedactionScanner(options: options).rects(in: window)

        let format = UIGraphicsImageRendererFormat()
        // Rasterise at the tier's scale, not at the device's. Capturing above the tier
        // only to downscale afterwards burns memory and time for pixels that get thrown
        // away; capturing below it caps the detail the tier is allowed to keep, which is
        // what made `high` indistinguishable from `medium` when this was pinned to 1.
        format.scale = options.quality.effectiveScale(forPointSize: bounds.size)
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { _ in
            // `drawHierarchy` rather than `layer.render(in:)`.
            //
            // `layer.render(in:)` walks the layer tree directly and silently omits
            // anything the compositor draws out-of-band: SwiftUI-rendered content,
            // UIVisualEffectView blurs, and Metal/CAMetalLayer surfaces. Those are
            // precisely the places PII hides, so a recorder built on `layer.render`
            // ships blank rectangles where sensitive content was — and looks correct
            // in a UIKit-only test app.
            //
            // `afterScreenUpdates: false`, because `true` is visible to the user.
            //
            // `true` forces UIKit to commit and re-render the entire window off-screen,
            // synchronously, before it draws. Once per second on the live key window,
            // that reads as a full-screen flash — the app looked like it was flickering
            // constantly, and it was this line.
            //
            // This carried a comment claiming `true` was mandatory: with `false` UIKit
            // returns the previously committed frame while the redaction rects come from
            // the current view tree, so a layout change between them leaves a mask in the
            // wrong place and exposes the text it was meant to cover. That skew was real,
            // but `layoutIfNeeded()` above was manufacturing it — it moved the tree ahead
            // of the committed frame on every capture. With it gone the two agree, and
            // `false` is both correct and invisible.
            //
            // This is what every mobile replay recorder does; sentry-cocoa's
            // `SentryDefaultViewRenderer` and `SentryViewRendererV2` both pass `false`
            // unconditionally, and neither calls `layoutIfNeeded` or `CATransaction.flush`.
            window.drawHierarchy(in: bounds, afterScreenUpdates: false)
        }

        return PendingFrame(image: image, redactions: redactions, timestamp: Date())
    }

    @MainActor
    static func activeWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }

        let candidates = (scenes.isEmpty
            ? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            : scenes)
            .flatMap(\.windows)

        return candidates.first(where: \.isKeyWindow) ?? candidates.first
    }
}
