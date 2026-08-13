import SwiftUI
import UIKit
import XCTest
@testable import MapleReplay

/// Reproduces the demo's floating debug bar, where masks were observed landing below the
/// text they were meant to cover.
@MainActor
final class DebugBarRedactionTests: XCTestCase {
    private struct Bar: View {
        var body: some View {
            VStack(spacing: 8) {
                HStack {
                    Button("Record") {}.buttonStyle(.borderedProminent)
                    Button("Trigger error") {}.buttonStyle(.bordered)
                    Spacer()
                }
                Picker("Mode", selection: .constant(0)) {
                    Text("Continuous").tag(0)
                    Text("Buffered").tag(1)
                }
                .pickerStyle(.segmented)
                Text("segment 2 · 6 frames · 6000 ms")
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 12)
        }
    }

    func testDumpBarRects() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 400))
        window.rootViewController = UIHostingController(rootView: Bar())
        window.isHidden = false
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        window.layoutIfNeeded()

        let dump = RedactionScanner(options: ReplayOptions())
            .debugRects(in: window)
            .map { "\($0.name) @ \(Int($0.rect.minX)),\(Int($0.rect.minY)) \(Int($0.rect.width))x\(Int($0.rect.height))" }
            .joined(separator: "\n  ")
        print("MASKED VIEWS:\n  \(dump)")

        // Dump the full tree so unmasked drawing views are visible too.
        print("TREE:\n\(Self.tree(window, depth: 0))")
    }

    private static func tree(_ view: UIView, depth: Int) -> String {
        let pad = String(repeating: "  ", count: depth)
        let frame = view.superview.map { view.convert(view.bounds, to: $0.window ?? $0) } ?? view.bounds
        var line = "\(pad)\(NSStringFromClass(type(of: view)))"
            + " @\(Int(frame.minY)) h\(Int(frame.height))"
            + " subviews=\(view.subviews.count)"
            + " contents=\(view.layer.contents != nil)"
            + " sublayers=\(view.layer.sublayers?.count ?? 0)"
        if let sublayers = view.layer.sublayers, !sublayers.isEmpty {
            let kinds = Set(sublayers.map { String(describing: type(of: $0)) }).sorted()
            line += " layerKinds=\(kinds.joined(separator: "|"))"
        }
        return ([line] + view.subviews.map { tree($0, depth: depth + 1) }).joined(separator: "\n")
    }
}
