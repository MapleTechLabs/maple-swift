import Foundation
import UIKit

/// Live overlay showing exactly which regions the recorder would redact.
///
/// This exists in milestone 1 rather than "later" on purpose. Verifying masking by
/// exporting a segment and opening the MP4 is a slow loop, and a slow loop is how
/// masking bugs survive to production. With the overlay on, a wrong mask is visible the
/// instant you navigate to the screen.
///
/// It runs the same `RedactionScanner` the recorder does, so what you see is what gets
/// painted — not a reimplementation that can drift.
public final class MaskingPreviewView: UIView {
    private var options: ReplayOptions
    private var displayLink: CADisplayLink?
    private var rects: [CGRect] = []

    public init(options: ReplayOptions) {
        self.options = options
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
    }

    private func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(refresh))
        // 4 Hz. The overlay only needs to feel live; scanning the view tree at 120 Hz
        // would make the very thing we are trying to measure feel slow.
        link.preferredFramesPerSecond = 4
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func refresh() {
        // Scan the window, matching exactly what the recorder captures. Scanning only
        // the immediate superview would miss everything outside this overlay's container,
        // which under SwiftUI is almost the entire screen.
        guard let host = window else { return }
        let scanned = RedactionScanner(options: options).rects(in: host, excluding: self)
            .map { convert($0, from: host) }
        guard scanned != rects else { return }
        rects = scanned
        setNeedsDisplay()
    }

    public override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.systemPink.withAlphaComponent(0.35).cgColor)
        context.setStrokeColor(UIColor.systemPink.cgColor)
        context.setLineWidth(1)
        for redaction in rects {
            context.fill(redaction)
            context.stroke(redaction)
        }
    }
}
