import Foundation
import MapleCore
import UIKit

/// Records touch locations so the replay shows where the user tapped.
///
/// Non-obvious but essential: a screenshot-based replay has no cursor and no visible
/// press state, so without this the video shows screens changing for no apparent reason.
/// Sentry ships the same component for the same reason.
final class TouchTracker {
    private let lock = NSLock()
    private var events: [RRWebEvent] = []
    /// Bounded so a long buffered window can't accumulate touches without limit.
    private let maxEvents = 2_000

    func record(interaction: TouchInteraction, at point: CGPoint) {
        let event = RRWebEvent.touch(
            timestamp: Date(), interaction: interaction, x: point.x, y: point.y
        )
        lock.lock()
        events.append(event)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }
        lock.unlock()
    }

    /// Touches within a time range, and drop everything at or before its end.
    func drain(until end: Date) -> [RRWebEvent] {
        let cutoff = end.epochMilliseconds
        lock.lock()
        defer { lock.unlock() }
        let matching = events.filter { $0.timestamp <= cutoff }
        events.removeAll { $0.timestamp <= cutoff }
        return matching
    }

    func removeAll() {
        lock.lock()
        events.removeAll()
        lock.unlock()
    }
}

/// Installs touch observation on `UIWindow` without swizzling.
///
/// A `UIGestureRecognizer` with `cancelsTouchesInView = false` and
/// `delaysTouchesBegan/Ended = false` observes every touch while remaining invisible to
/// the app's own gesture handling. Swizzling `sendEvent:` would also work and is what
/// several SDKs do, but it mutates a UIKit class the host app also owns — an
/// unnecessary risk for a capability a recognizer already provides.
final class TouchObserver: NSObject, UIGestureRecognizerDelegate {
    private weak var window: UIWindow?
    private var recognizer: UIGestureRecognizer?
    private let tracker: TouchTracker

    init(tracker: TouchTracker) {
        self.tracker = tracker
    }

    @MainActor
    func attach(to window: UIWindow) {
        detach()
        let recognizer = PassthroughGestureRecognizer(tracker: tracker)
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

    /// Never block another recognizer — this one only observes.
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool { true }
}

private final class PassthroughGestureRecognizer: UIGestureRecognizer {
    private let tracker: TouchTracker

    init(tracker: TouchTracker) {
        self.tracker = tracker
        super.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        report(touches, as: .touchStart)
        // Counted on *began* rather than ended, so a tap that turns into a scroll still
        // counts as an interaction. `ClickCount` is a liveness signal, not a tap total.
        SessionSink.shared.recordClick()
        // Stay in .possible forever so the recognizer never fires, never transitions to
        // .began, and therefore never interferes with the app's gestures.
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
        tracker.record(interaction: interaction, at: touch.location(in: view))
    }
}
