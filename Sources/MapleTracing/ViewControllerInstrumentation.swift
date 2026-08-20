import Foundation
import MapleCore
import ObjectiveC
import UIKit

/// Screen tracking.
///
/// Two ways in, because iOS has two UI frameworks and only one of them has a view
/// controller per screen:
///
///  * UIKit — `viewDidAppear`/`viewDidDisappear` are swizzled, giving a `ui.screen` span
///    whose duration is the time the screen was actually on screen.
///  * SwiftUI — every screen is a `UIHostingController`, so the swizzle sees *one*
///    controller for the whole app. `MapleTracing.trackScreen(_:)` is the way in, called
///    from `.onAppear`.
///
/// Each appearance also emits a `navigation` session event. On the web that is the
/// widest-coverage replay signal there is — every session, every SDK version — and it is
/// what the session transcript and the analytics page are built on. iOS emitted none
/// before this, which is why a mobile recording had no timeline beside the video.
public enum ViewControllerInstrumentation {
    nonisolated(unsafe) private static var tracerBox: Tracer?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var installed = false

    /// Screens whose span is still open. Weak, so a screen that is never closed
    /// properly costs a nil slot rather than keeping its span alive for the life
    /// of the process.
    nonisolated(unsafe) private static var openScreens: [WeakSpan] = []
    nonisolated(unsafe) private static var backgroundObserver: (any NSObjectProtocol)?

    static var tracer: Tracer? {
        lock.lock(); defer { lock.unlock() }
        return tracerBox
    }

    static func install(tracer: Tracer) {
        lock.lock()
        tracerBox = tracer
        let needsSwizzle = !installed
        installed = true
        lock.unlock()

        // Two lifetimes, deliberately separate. Swizzling is once per process and
        // is never undone. The notification observer *is* undone by `uninstall()`,
        // so it has to be re-established on every install — folding it into the
        // `needsSwizzle` branch means a stop/start cycle silently loses screen
        // bounding, which is exactly how the first version of this shipped.
        observeBackgrounding()

        guard needsSwizzle else { return }
        swizzle(#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.maple_viewDidAppear(_:)))
        swizzle(#selector(UIViewController.viewDidDisappear(_:)), #selector(UIViewController.maple_viewDidDisappear(_:)))
    }

    static func uninstall() {
        lock.lock()
        tracerBox = nil
        openScreens = []
        let observer = backgroundObserver
        backgroundObserver = nil
        lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    // MARK: - Bounding

    /// Close every open screen span when the app leaves the foreground.
    ///
    /// A `ui.screen` span runs from `viewDidAppear` to `viewDidDisappear`, and
    /// neither fires when the app is backgrounded — nor, in SwiftUI, when a tab's
    /// root view stops being the visible tab. A screen left open overnight
    /// therefore produced one span covering the whole night: spans of eleven hours
    /// reached the warehouse, where nothing distinguishes them from an eleven-hour
    /// request and they dominate every latency percentile the service reports.
    ///
    /// Ending here is also the more honest reading of the signal. `ui.screen`
    /// measures how long a screen was in front of someone, and nobody is looking
    /// at it while the app is in the background.
    ///
    /// Deliberately no automatic restart on foreground. The span was handed to
    /// whoever asked for it — a `UIViewController`'s associated object, or
    /// SwiftUI's `@State` — and a replacement started here would be one that
    /// caller never sees and never ends, which is the same leak from the other
    /// end. A host that wants the second sitting counted re-opens it itself;
    /// `Span.end()` is idempotent, so the stale reference it still holds is
    /// harmless.
    private static func observeBackgrounding() {
        lock.lock()
        let alreadyObserving = backgroundObserver != nil
        lock.unlock()
        guard !alreadyObserving else { return }

        let observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { _ in
            endOpenScreens(reason: "background")
        }
        lock.lock()
        backgroundObserver = observer
        lock.unlock()
    }

    /// End every open screen span, recording why. Public for a host app that
    /// knows it has left a screen before the notification would say so.
    public static func endOpenScreens(reason: String) {
        lock.lock()
        let screens = openScreens
        openScreens = []
        lock.unlock()

        for entry in screens {
            guard let span = entry.span, !span.hasEnded else { continue }
            span.setAttribute("maple.screen.end_reason", .string(reason))
            span.end()
        }
    }

    private static func track(_ span: Span) {
        lock.lock(); defer { lock.unlock() }
        // Drop slots whose span has been released or already ended, so a long
        // session does not accumulate one entry per screen ever visited.
        openScreens.removeAll { $0.span == nil || $0.span?.hasEnded == true }
        openScreens.append(WeakSpan(span))
    }

    /// Screen spans still open. For tests.
    static var openScreenCount: Int {
        lock.lock(); defer { lock.unlock() }
        return openScreens.filter { $0.span?.hasEnded == false }.count
    }

    /// `Span` is a class, so this can hold it weakly — an array of `weak` needs a box.
    private final class WeakSpan {
        weak var span: Span?
        init(_ span: Span) { self.span = span }
    }

    /// Record a screen appearance by name. Public because SwiftUI has no controller to
    /// swizzle; also the escape hatch when a controller's class name is not the name a
    /// human would call the screen.
    public static func screenAppeared(_ name: String) -> Span? {
        SessionSink.shared.recordPageView()
        // The span is started first so the event can name its trace. Emitting first left
        // every `navigation` row with an empty `TraceId`, which is the column the
        // transcript uses to jump from a screen to the requests it made.
        let span = tracer?.startSpan(
            name: "ui.screen",
            kind: .internal,
            attributes: ["screen.name": .string(name)]
        )
        SessionSink.shared.emit(
            SessionEventDraft(kind: .navigation, traceId: span?.traceId, message: name)
        )
        // Registered so backgrounding can close it. Neither `viewDidDisappear`
        // nor SwiftUI's `onDisappear` fires on the way to the background, and a
        // screen span nobody closes runs until the process dies.
        if let span { track(span) }
        return span
    }

    /// Controllers that are scaffolding rather than screens.
    ///
    /// Matched on the framework prefix, not an allowlist of class names: a navigation
    /// controller, a tab bar controller and a system alert all appear and disappear
    /// constantly, and none of them is a screen a user would name. An app's own
    /// controllers do not carry these prefixes.
    static func isFrameworkController(_ controller: UIViewController) -> Bool {
        let name = NSStringFromClass(type(of: controller))
        if name.hasPrefix("_") { return true }
        for prefix in ["UI", "SwiftUI", "SFSafari", "AV", "PU", "PH", "SLComposeService"] {
            if name.hasPrefix(prefix) { return true }
        }
        return false
    }

    static func screenName(for controller: UIViewController) -> String {
        let raw = NSStringFromClass(type(of: controller))
        // Swift class names are mangled as `Module.Class`; the module is noise on a
        // screen label and identical for every row.
        return raw.components(separatedBy: ".").last ?? raw
    }

    private static func swizzle(_ original: Selector, _ replacement: Selector) {
        guard let originalMethod = class_getInstanceMethod(UIViewController.self, original),
              let replacementMethod = class_getInstanceMethod(UIViewController.self, replacement) else {
            MapleLog.notice("MapleTracing", "could not instrument \(original); screen spans are off")
            return
        }
        method_exchangeImplementations(originalMethod, replacementMethod)
    }
}

nonisolated(unsafe) private var screenSpanKey: UInt8 = 0

extension UIViewController {
    @objc func maple_viewDidAppear(_ animated: Bool) {
        maple_viewDidAppear(animated)
        guard ViewControllerInstrumentation.tracer != nil,
              !ViewControllerInstrumentation.isFrameworkController(self) else { return }
        let span = ViewControllerInstrumentation.screenAppeared(
            ViewControllerInstrumentation.screenName(for: self)
        )
        objc_setAssociatedObject(self, &screenSpanKey, span, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    @objc func maple_viewDidDisappear(_ animated: Bool) {
        maple_viewDidDisappear(animated)
        guard let span = objc_getAssociatedObject(self, &screenSpanKey) as? Span else { return }
        span.end()
        objc_setAssociatedObject(self, &screenSpanKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}
