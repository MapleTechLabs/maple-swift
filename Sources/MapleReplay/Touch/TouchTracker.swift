import Foundation
import MapleCore
import UIKit

/// One observed touch, in window points.
struct TouchSample: Equatable {
    let timestamp: Date
    let interaction: TouchInteraction
    let location: CGPoint
}

/// Records touch locations so the replay shows where the user tapped.
///
/// Non-obvious but essential: a screenshot-based replay has no cursor and no visible
/// press state, so without this the video shows screens changing for no apparent reason.
final class TouchTracker {
    private let lock = NSLock()
    private var samples: [TouchSample] = []
    private var lastMoveAt = Date.distantPast

    /// Bounded so a long buffered window can't accumulate touches without limit.
    let maxSamples: Int
    /// Moves arrive at the display rate (120 Hz on ProMotion). A trail at 10 Hz is all a
    /// replay at 1 fps can show, and every sample is bytes in every segment.
    static let moveInterval: TimeInterval = 0.1

    init(maxSamples: Int = 2_000) {
        self.maxSamples = max(1, maxSamples)
    }

    func record(interaction: TouchInteraction, at point: CGPoint, now: Date = Date()) {
        guard point.x.isFinite, point.y.isFinite else { return }
        lock.lock()
        defer { lock.unlock() }
        if interaction == .touchMove {
            guard now.timeIntervalSince(lastMoveAt) >= Self.moveInterval else { return }
            lastMoveAt = now
        }
        samples.append(TouchSample(timestamp: now, interaction: interaction, location: point))
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }

    /// Touches at or before `end`, removed from the tracker. Anything older than
    /// `notBefore` is discarded rather than returned.
    func drain(until end: Date, notBefore start: Date = .distantPast) -> [TouchSample] {
        lock.lock()
        defer { lock.unlock() }
        let matching = samples.filter { $0.timestamp <= end && $0.timestamp >= start }
        samples.removeAll { $0.timestamp <= end }
        return matching
    }

    /// Forget touches older than `cutoff`. Called as the buffer evicts frames, so a
    /// buffered session holds touches for the same window it holds video.
    func discard(olderThan cutoff: Date) {
        lock.lock()
        samples.removeAll { $0.timestamp < cutoff }
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    func removeAll() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

/// Installs touch observation on `UIWindow` without swizzling.
///
/// A `UIGestureRecognizer` with `cancelsTouchesInView = false` and
/// `delaysTouchesBegan/Ended = false` observes every touch while remaining invisible to
/// the app's own gesture handling. Swizzling `sendEvent:` would also work, but it
/// mutates a UIKit class the host app also owns.
final class TouchObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var window: UIWindow?
    private var recognizer: PassthroughGestureRecognizer?
    private let tracker: TouchTracker
    private let recordLocations: Bool
    /// The scanner's forced-mask rule for one view (masked classes, always-masked
    /// types), so a touch on one is suppressed before any capture has found it.
    var isForcedView: (UIView) -> Bool = { _ in false }

    /// Regions the last capture masked, in window points. Main thread only.
    ///
    /// A touch's position is as revealing as the pixels under it: taps on a custom PIN
    /// pad spell the PIN even when every digit is masked. So a touch inside a masked
    /// region keeps counting as a click but its location is never recorded. The rects
    /// are up to one capture interval old; the view under the finger is checked live.
    var maskedRegions: [CGRect] = []

    init(tracker: TouchTracker, recordLocations: Bool = true) {
        self.tracker = tracker
        self.recordLocations = recordLocations
    }

    @MainActor
    func attach(to window: UIWindow) {
        guard window !== self.window || recognizer == nil else { return }
        detach()
        let recognizer = PassthroughGestureRecognizer(observer: self)
        recognizer.delegate = self
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        window.addGestureRecognizer(recognizer)
        self.window = window
        self.recognizer = recognizer
    }

    @MainActor
    func detach() {
        if let recognizer, let window { window.removeGestureRecognizer(recognizer) }
        recognizer = nil
        window = nil
    }

    var attachedWindow: UIWindow? { window }

    /// Never block another recognizer: this one only observes.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }

    /// SwiftUI mask regions found when the current gesture began. A marker is a sibling
    /// of the content it masks, not an ancestor of the touched view, and the last
    /// capture's regions are empty until the first frame of a run.
    private var gestureMarkerRegions: [CGRect] = []

    fileprivate func report(_ touch: UITouch, in window: UIView, as interaction: TouchInteraction) {
        guard recordLocations else { return }
        if interaction == .touchStart { gestureMarkerRegions = Self.maskMarkerRegions(in: window) }
        let point = touch.location(in: window)
        guard !isSensitive(point: point, touchedView: touch.view) else { return }
        tracker.record(interaction: interaction, at: point)
    }

    /// Frames of every visible `.mapleReplayMask()` marker, in `root`'s space.
    static func maskMarkerRegions(in root: UIView) -> [CGRect] {
        var regions: [CGRect] = []
        var stack: [UIView] = [root]
        while let view = stack.popLast() {
            guard !view.isHidden else { continue }
            if let marker = view as? ReplayMarkerView {
                if marker.kind == .mask { regions.append(marker.convert(marker.bounds, to: root)) }
                continue
            }
            stack.append(contentsOf: view.subviews)
        }
        return regions
    }

    /// Whether a touch at `point` must not be recorded.
    func isSensitive(point: CGPoint, touchedView: UIView?) -> Bool {
        if maskedRegions.contains(where: { $0.contains(point) }) { return true }
        if gestureMarkerRegions.contains(where: { $0.contains(point) }) { return true }
        var view = touchedView
        while let current = view {
            if current is UIKeyInput || current.mapleReplayMaskOverride == true || isForcedView(current) { return true }
            view = current.superview
        }
        return false
    }
}

private final class PassthroughGestureRecognizer: UIGestureRecognizer {
    private weak var observer: TouchObserver?

    init(observer: TouchObserver) {
        self.observer = observer
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches, as: .touchStart)
        // Counted on *began* rather than ended, so a tap that turns into a scroll still
        // counts as an interaction. `ClickCount` is a liveness signal, not a tap total.
        SessionSink.shared.recordClick()
        // Stay in .possible forever so the recognizer never fires and never interferes
        // with the app's gestures.
        state = .possible
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches, as: .touchMove)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches, as: .touchEnd)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches, as: .touchEnd)
    }

    private func report(_ touches: Set<UITouch>, as interaction: TouchInteraction) {
        guard let touch = touches.first, let view = self.view else { return }
        observer?.report(touch, in: view, as: interaction)
    }
}
