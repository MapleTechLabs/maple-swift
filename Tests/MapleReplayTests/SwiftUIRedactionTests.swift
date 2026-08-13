import SwiftUI
import UIKit
import XCTest
@testable import MapleReplay

/// Redaction against a real SwiftUI hierarchy.
///
/// The UIKit tests exercise classes the scanner knows by name. These exercise the case
/// the design actually turns on: SwiftUI's private backing views, whose names change
/// between iOS releases and which we deliberately refuse to enumerate.
@MainActor
final class SwiftUIRedactionTests: XCTestCase {
    private struct Screen: View {
        @State var email = "ada.lovelace@example.com"
        var body: some View {
            List {
                Section("Account") {
                    LabeledContent("Name", value: "Ada Lovelace")
                    HStack {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable().frame(width: 44, height: 44)
                        Text("Ada Lovelace")
                    }
                }
                Section("Credentials") {
                    TextField("Email", text: $email)
                    SecureField("Password", text: .constant("hunter2"))
                }
            }
        }
    }

    private func hostedWindow() -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UIHostingController(rootView: Screen())
        window.isHidden = false
        window.layoutIfNeeded()
        // Force a full layout pass so SwiftUI has materialised its backing views.
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return window
    }

    /// The characteristic failure of a mask-unknown-by-default rule: one unrecognised
    /// full-screen leaf swallows the whole screen. Safe, but the replay is then a solid
    /// block and worth nothing.
    func testDoesNotMaskTheEntireScreen() {
        let window = hostedWindow()
        let rects = RedactionScanner(options: ReplayOptions()).rects(in: window)

        let windowArea = window.bounds.width * window.bounds.height
        let maskedArea = rects.reduce(0) { $0 + $1.width * $1.height }
        let coverage = maskedArea / windowArea

        XCTAssertLessThan(
            coverage, 0.9,
            """
            Masked \(Int(coverage * 100))% of the screen from \(rects.count) rect(s). \
            Offenders: \(diagnose(window))
            """
        )
    }

    /// The other side of the same coin: masking must still cover the sensitive content.
    func testStillMasksSensitiveContent() {
        let window = hostedWindow()
        let rects = RedactionScanner(options: ReplayOptions()).rects(in: window)
        XCTAssertFalse(rects.isEmpty, "SwiftUI text must be masked")
    }

    private func diagnose(_ window: UIWindow) -> String {
        RedactionScanner(options: ReplayOptions())
            .debugRects(in: window)
            .sorted { $0.rect.width * $0.rect.height > $1.rect.width * $1.rect.height }
            .prefix(6)
            .map { "\($0.name) \(Int($0.rect.width))x\(Int($0.rect.height))" }
            .joined(separator: ", ")
    }
}
