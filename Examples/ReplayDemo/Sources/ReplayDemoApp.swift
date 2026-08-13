import MapleReplay
import SwiftUI

@main
struct ReplayDemoApp: App {
    @StateObject private var controller = RecorderController()

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                TabView {
                    SwiftUIScreen()
                        .tabItem { Label("SwiftUI", systemImage: "swift") }
                    UIKitScreen()
                        .tabItem { Label("UIKit", systemImage: "square.stack") }
                }

                DebugBar(controller: controller)
            }
            .overlay {
                if controller.showMaskPreview {
                    MaskPreviewOverlay(options: controller.options)
                        .allowsHitTesting(false)
                        .ignoresSafeArea()
                }
            }
        }
    }
}

/// Owns recorder state for the demo. Everything here is demo scaffolding — the SDK
/// itself has no opinion about how a host app drives it.
@MainActor
final class RecorderController: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case continuous, buffered
        var id: String { rawValue }
    }

    @Published var mode: Mode = .continuous
    @Published var quality: ReplayQuality = .medium
    @Published var showMaskPreview = false
    @Published private(set) var isRecording = false
    @Published private(set) var segments: [SegmentArtifacts] = []
    @Published private(set) var sessionId: String?

    var options: ReplayOptions {
        var options = ReplayOptions()
        options.quality = quality
        options.flushPolicy = mode == .continuous ? .defaultContinuous : .defaultBuffered
        return options
    }

    func start() {
        guard !isRecording else { return }
        segments = []
        MapleReplay.shared.onSegment = { [weak self] artifact in
            self?.segments.append(artifact)
        }
        MapleReplay.shared.start(
            options: options, serviceName: "replay-demo", environment: "development"
        )
        sessionId = MapleReplay.shared.sessionId
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        MapleReplay.shared.stop()
        isRecording = false
    }

    func triggerError() {
        MapleReplay.shared.flush(trigger: "error")
    }

    /// Printed rather than shown in the UI so it survives in the device log alongside the
    /// simulator container path — that's how the segments actually get inspected.
    func logOutputLocation() {
        guard let directory = MapleReplay.shared.outputDirectory else { return }
        print("[ReplayDemo] segments at: \(directory.path)")
    }
}
