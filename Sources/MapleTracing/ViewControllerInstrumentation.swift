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

        guard needsSwizzle else { return }
        swizzle(#selector(UIViewController.viewDidAppear(_:)), #selector(UIViewController.maple_viewDidAppear(_:)))
        swizzle(#selector(UIViewController.viewDidDisappear(_:)), #selector(UIViewController.maple_viewDidDisappear(_:)))
    }

    static func uninstall() {
        lock.lock()
        tracerBox = nil
        lock.unlock()
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
