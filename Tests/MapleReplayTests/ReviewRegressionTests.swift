import UIKit
import XCTest
@testable import MapleReplay

/// Regressions for masking gaps found in review of the per-view masking change.
@MainActor
final class UnmaskScopeTests: XCTestCase {
    private func label(_ frame: CGRect) -> UILabel {
        let label = UILabel(frame: frame)
        label.text = "4111 1111 1111 1111"
        return label
    }

    /// An unmask region covers its own screen's content, not a screen presented over it.
    func testUnmaskRegionDoesNotReachAScreenDrawnOverIt() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let base = UIViewController()
        window.rootViewController = base
        window.isHidden = false
        let card = CGRect(x: 20, y: 100, width: 300, height: 200)
        let marker = ReplayMarkerView(kind: .unmask)
        marker.frame = card
        base.view.addSubview(marker)
        base.view.addSubview(label(CGRect(x: 40, y: 120, width: 200, height: 20)))

        let overlay = UIViewController()
        base.addChild(overlay)
        overlay.view.frame = window.bounds
        overlay.view.backgroundColor = .clear
        base.view.addSubview(overlay.view)
        let alertText = CGRect(x: 40, y: 200, width: 200, height: 20)
        overlay.view.addSubview(label(alertText))

        let rects = RedactionScanner(options: ReplayOptions()).rects(in: window)
        XCTAssertFalse(rects.contains { $0.contains(CGRect(x: 40, y: 120, width: 200, height: 20)) },
                       "the unmasked card's own label should be shown")
        XCTAssertTrue(rects.contains { $0.contains(alertText) }, "the overlay's label must stay masked: \(rects)")
    }

    /// A masked class keeps its mask under a content-masked parent inside an unmask region.
    func testMaskedClassUnderMaskedParentSurvivesAnUnmaskRegion() {
        final class Secret: UIView {}
        var options = ReplayOptions()
        options.maskedViewClasses = [Secret.self]
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let marker = ReplayMarkerView(kind: .unmask)
        marker.frame = root.bounds
        root.addSubview(marker)
        let parent = label(CGRect(x: 10, y: 10, width: 100, height: 20))
        let secret = Secret(frame: CGRect(x: 0, y: 30, width: 50, height: 50))
        parent.addSubview(secret)
        root.addSubview(parent)

        let rects = RedactionScanner(options: options).rects(in: root)
        XCTAssertTrue(rects.contains { $0.contains(CGRect(x: 10, y: 40, width: 50, height: 50)) }, "\(rects)")
    }

    /// Touches over a SwiftUI mask are suppressed from the first touch of a run, before
    /// any capture has produced masked regions.
    func testMaskMarkerRegionsAreFoundWithoutACapture() {
        let root = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let container = UIView(frame: CGRect(x: 0, y: 100, width: 400, height: 400))
        let marker = ReplayMarkerView(kind: .mask)
        marker.frame = CGRect(x: 50, y: 50, width: 200, height: 200)
        container.addSubview(marker)
        root.addSubview(container)
        let hidden = ReplayMarkerView(kind: .mask)
        hidden.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        hidden.isHidden = true
        root.addSubview(hidden)

        XCTAssertEqual(TouchObserver.maskMarkerRegions(in: root), [CGRect(x: 50, y: 150, width: 200, height: 200)])
    }
}

final class SpoolManifestUpdateTests: XCTestCase {
    private func spool(in root: URL) -> FrameSpool {
        FrameSpool(
            root: root,
            manifest: SpoolManifest(
                sessionId: "s1", startedAt: 1_700_000_000, frameRate: 1, quality: "low",
                serviceName: "app", environment: nil, userId: "", nextChunkSeq: 0, recoveryAttempts: 0
            ),
            capacity: 5,
            byteBudget: 1_000_000
        )
    }

    private func manifest(in root: URL) throws -> SpoolManifest {
        let data = try Data(contentsOf: FrameSpool.sessionDirectory(root: root, sessionId: "s1")
            .appendingPathComponent(FrameSpool.manifestName))
        return try JSONDecoder().decode(SpoolManifest.self, from: data)
    }

    /// The crash-recovered row outranks every live row, so the spool must carry the
    /// user id signed in after the session started.
    func testUserIdChangeReachesTheManifest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = spool(in: root)
        spool.updateUserId("user-42")
        XCTAssertEqual(try manifest(in: root).userId, "user-42")
    }

    /// Another run of the session can take chunk numbers after this spool was created.
    func testManifestFollowsTheSessionChunkCounter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spool = spool(in: root)
        let frame = CapturedFrame(jpeg: Data([0xFF, 0xD8, 0xFF]), timestamp: Date(), size: CGSize(width: 32, height: 32))
        spool.append(frame, nextChunkSeq: 7)
        XCTAssertEqual(try manifest(in: root).nextChunkSeq, 7)
    }
}
