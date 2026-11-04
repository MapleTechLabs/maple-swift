import UIKit
import XCTest
@testable import MapleReplay

/// Painter cost per frame, skeleton against solid. Opt-in: `MAPLE_BENCH=1`
/// (`TEST_RUNNER_MAPLE_BENCH=1` through xcodebuild). Prints a table; asserts nothing.
final class PainterBenchmarkTests: XCTestCase {
    func testPainterCostPerFrame() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MAPLE_BENCH"] == "1", "set MAPLE_BENCH=1")
        let window = CGSize(width: 393, height: 852)
        let scenes: [(String, [CGRect], [MaskKind])] = [
            ("list 40", Self.listScreen(rows: 10, in: window)),
            ("dense 150", Self.listScreen(rows: 38, in: window)),
            ("one full-screen block", ([CGRect(x: 0, y: 100, width: 393, height: 700)], [.unknown])),
        ].map { ($0.0, $0.1.0, $0.1.1) }
        var lines = ["scene | quality | solid ms | skeleton ms | overhead"]
        for (name, rects, kinds) in scenes {
            for quality in ReplayQuality.allCases {
                let source = Self.sourceImage(window, scale: quality.effectiveScale(forPointSize: window))
                let pending = PendingFrame(image: source, redactions: rects, kinds: kinds, timestamp: Date())
                var options = ReplayOptions()
                options.quality = quality
                options.maskStyle = .solid
                let solid = Self.medianMillis { _ = RedactionPainter.redactAndCompress(pending, options: options) }
                options.maskStyle = .skeleton
                let skeleton = Self.medianMillis { _ = RedactionPainter.redactAndCompress(pending, options: options) }
                lines.append(String(format: "%@ | %@ | %.2f | %.2f | %+.2f ms", name, quality.rawValue, solid, skeleton, skeleton - solid))
            }
        }
        print("PAINTER BENCH\n" + lines.joined(separator: "\n"))
    }

    private static func medianMillis(runs: Int = 25, _ body: () -> Void) -> Double {
        for _ in 0..<3 { body() }
        let samples = (0..<runs).map { _ -> Double in
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        }
        return samples.sorted()[runs / 2]
    }

    /// Rows of avatar + title + subtitle + amount, the shape of a typical list screen.
    private static func listScreen(rows: Int, in size: CGSize) -> ([CGRect], [MaskKind]) {
        var rects: [CGRect] = [CGRect(x: 16, y: 60, width: 140, height: 34)]
        var kinds: [MaskKind] = [.text]
        let rowHeight = (size.height - 120) / CGFloat(rows)
        for row in 0..<rows {
            let y = 110 + CGFloat(row) * rowHeight
            rects += [
                CGRect(x: 16, y: y + 4, width: min(40, rowHeight - 8), height: min(40, rowHeight - 8)),
                CGRect(x: 66, y: y + 4, width: 180, height: 16),
                CGRect(x: 66, y: y + 24, width: 140, height: 12),
                CGRect(x: 320, y: y + 4, width: 56, height: 16),
            ]
            kinds += [.image, .text, .text, .unknown]
        }
        return (rects, kinds)
    }

    private static func sourceImage(_ size: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for i in 0..<60 {
                UIColor(hue: CGFloat(i) / 60, saturation: 0.6, brightness: 0.8, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(i * 37 % 360), y: CGFloat(i * 14), width: 30, height: 10))
            }
        }
    }
}
