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

        // Flush any pending layout before doing anything else, so the bitmap and the
        // redaction rects describe the same layout state. See the ordering note below.
        window.layoutIfNeeded()

        let format = UIGraphicsImageRendererFormat()
        // Capture at 1x. The frame gets downscaled to the quality tier's maxDimension
        // anyway, so rendering at 3x only burns memory and time.
        format.scale = 1
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
            // `afterScreenUpdates: true` is mandatory, not a quality dial.
            //
            // With `false`, UIKit returns the *previously committed* frame while the
            // redaction rects are computed from the *current* view tree. Any layout
            // change between those two states puts the masks in the wrong place — and a
            // mask in the wrong place means the text it was meant to cover is now
            // visible in the recording. This was observed: a status line that grew by a
            // row left its own text exposed and painted the redaction below it.
            //
            // The synchronous render costs a few milliseconds. At 1 fps that is an
            // irrelevant fraction of a second, and it is the difference between a
            // correct recording and one that leaks whatever moved.
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }

        // Scan *after* drawing. `drawHierarchy` commits pending updates, so the tree we
        // walk now is exactly the tree that was rasterised above — no layout pass can
        // intervene, because this whole function is synchronous on the main thread.
        let redactions = RedactionScanner(options: options).rects(in: window)

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
