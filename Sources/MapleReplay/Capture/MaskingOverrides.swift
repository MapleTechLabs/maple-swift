import ObjectiveC
import SwiftUI
import UIKit

private let maskOverrideKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

extension UIView {
    /// Always redact this view and everything inside it, whatever the masking options say.
    public func mapleReplayMask() {
        mapleReplayMaskOverride = true
    }

    /// Never redact this view or anything inside it, except secure text entry, which is
    /// masked no matter what. Applies to this instance only; subclasses and other
    /// instances are unaffected.
    public func mapleReplayUnmask() {
        mapleReplayMaskOverride = false
    }

    /// Back to the masking options' decision.
    public func mapleReplayClearMaskOverride() {
        mapleReplayMaskOverride = nil
    }

    var mapleReplayMaskOverride: Bool? {
        get { (objc_getAssociatedObject(self, maskOverrideKey) as? NSNumber)?.boolValue }
        set {
            objc_setAssociatedObject(
                self, maskOverrideKey, newValue.map(NSNumber.init(value:)), .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }
}

extension View {
    /// Always redact this view in session replays.
    ///
    /// SwiftUI views have no class to list in `maskedViewClasses`, so this marks the
    /// region instead: the recorder masks whatever is drawn inside this view's frame, and
    /// touches inside it are not recorded.
    public func mapleReplayMask() -> some View {
        background(ReplayMarker(kind: .mask))
    }

    /// Never redact this view in session replays, except text fields, which stay masked.
    ///
    /// Masks that lie entirely inside this view's frame are dropped, so keep it on the
    /// smallest view that is safe to show.
    public func mapleReplayUnmask() -> some View {
        background(ReplayMarker(kind: .unmask))
    }
}

/// The UIKit view a SwiftUI masking modifier leaves in the hierarchy. Its frame is the
/// modified view's frame, which is all the scanner needs.
final class ReplayMarkerView: UIView {
    enum Kind { case mask, unmask }
    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

private struct ReplayMarker: UIViewRepresentable {
    let kind: ReplayMarkerView.Kind

    func makeUIView(context: Context) -> ReplayMarkerView { ReplayMarkerView(kind: kind) }
    func updateUIView(_ uiView: ReplayMarkerView, context: Context) {}
}
