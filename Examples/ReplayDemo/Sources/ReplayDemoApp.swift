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

    /// Ingest target, overridable at launch so the demo can be pointed at a local
    /// gateway without an edit-and-rebuild cycle:
    ///
    /// ```
    /// MAPLE_ENDPOINT=http://127.0.0.1:3475 MAPLE_INGEST_KEY=maple_pk_… <run the app>
    /// ```
    ///
    /// `MAPLE_TEST` is the gateway's sentinel key: it authenticates, and everything sent
    /// under it is accepted and discarded.
    private var endpoint: URL {
        ProcessInfo.processInfo.environment["MAPLE_ENDPOINT"]
            .flatMap(URL.init(string:)) ?? URL(string: "https://ingest.maple.dev")!
    }

    private var ingestKey: String {
        ProcessInfo.processInfo.environment["MAPLE_INGEST_KEY"] ?? "MAPLE_TEST"
    }

    var options: ReplayOptions {
        var options = ReplayOptions()
        options.quality = quality
        options.flushPolicy = mode == .continuous ? .defaultContinuous : .defaultBuffered
        options.ingestKey = ingestKey
        options.endpoint = endpoint
        // The demo is the surface these get inspected on, so keep the disk copy: the
        // chunk on disk is byte-for-byte the body that was POSTed.
        options.writeSegmentsToDisk = true
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
        isRecording = MapleReplay.shared.isRecording
        print("[ReplayDemo] endpoint=\(endpoint.absoluteString) session=\(sessionId ?? "none")")
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
