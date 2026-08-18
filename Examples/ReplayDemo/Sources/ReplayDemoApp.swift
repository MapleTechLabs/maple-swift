import Maple
import SwiftUI

@main
struct ReplayDemoApp: App {
    @StateObject private var controller = RecorderController()

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .bottom) {
                TabView {
                    OrdersScreen()
                        .mapleScreen("Orders")
                        .tabItem { Label("Orders", systemImage: "shippingbox") }
                    NetworkScreen()
                        .tabItem { Label("Network", systemImage: "network") }
                    SwiftUIScreen()
                        .mapleScreen("SwiftUIShowcase")
                        .tabItem { Label("SwiftUI", systemImage: "swift") }
                    UIKitScreen()
                        .mapleScreen("UIKitShowcase")
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

    /// Ingest target.
    ///
    /// A shipped app is configured from `Info.plist`, which this target fills from build
    /// settings (see `project.yml`) — that is what a deploy pipeline sets, and leaving
    /// these `nil` is what lets the SDK read them.
    ///
    /// The environment variables are a *development* override on top, because
    /// `ProcessInfo.environment` is populated only by Xcode and `simctl` and so exists
    /// nowhere a real user runs the app:
    ///
    /// ```
    /// SIMCTL_CHILD_MAPLE_ENDPOINT=http://127.0.0.1:3475 \
    /// SIMCTL_CHILD_MAPLE_INGEST_KEY=maple_pk_… xcrun simctl launch booted dev.maple.ReplayDemo
    /// ```
    ///
    /// `MAPLE_TEST` is the gateway's sentinel key: it authenticates, and everything sent
    /// under it is accepted and discarded.
    private var endpoint: URL? {
        ProcessInfo.processInfo.environment["MAPLE_ENDPOINT"].flatMap(URL.init(string:))
    }

    private var ingestKey: String? {
        ProcessInfo.processInfo.environment["MAPLE_INGEST_KEY"]
    }

    var options: ReplayOptions {
        var options = ReplayOptions()
        options.quality = quality
        options.flushPolicy = mode == .continuous ? .defaultContinuous : .defaultBuffered
        // The demo is the surface these get inspected on, so keep the disk copy: the
        // chunk on disk is byte-for-byte the body that was POSTed.
        options.writeSegmentsToDisk = true
        // Overridable so the two masking policies can be compared without a rebuild:
        //   MAPLE_MASK_ALL_TEXT=0 MAPLE_MASK_ALL_IMAGES=0 <run>
        if let text = ProcessInfo.processInfo.environment["MAPLE_MASK_ALL_TEXT"] {
            options.maskAllText = text != "0"
        }
        if let images = ProcessInfo.processInfo.environment["MAPLE_MASK_ALL_IMAGES"] {
            options.maskAllImages = images != "0"
        }
        return options
    }

    func start() {
        guard !isRecording else { return }
        segments = []
        MapleReplay.shared.onSegment = { [weak self] artifact in
            self?.segments.append(artifact)
        }
        var mapleOptions = MapleOptions()
        // Both `nil` unless overridden for development, so the values from Info.plist
        // win — which is the path a real build takes.
        mapleOptions.ingestKey = ingestKey
        mapleOptions.endpoint = endpoint
        mapleOptions.replay = options
        // Left at the default (`nil`) so every host except the ingest endpoint gets a
        // `traceparent` — which is what makes the demo's requests continue into the
        // backend's traces without configuring anything.
        mapleOptions.tracing.tracePropagationTargets = nil

        // No serviceName or environment here on purpose: they come from Info.plist, so
        // this call is what a host app with a configured pipeline actually writes.
        Maple.start(options: mapleOptions)
        sessionId = MapleReplay.shared.sessionId
        isRecording = MapleReplay.shared.isRecording
        let plist = MapleBundleConfiguration.read()
        let effectiveEndpoint = endpoint ?? plist.endpoint ?? MapleOptions.defaultEndpoint
        let hasKey = (ingestKey ?? plist.ingestKey) != nil
        print("""
        [ReplayDemo] endpoint=\(effectiveEndpoint.absoluteString) \
        service=\(plist.serviceName ?? "<unset>") env=\(plist.environment ?? "<unset>") \
        key=\(hasKey ? "set" : "MISSING") session=\(sessionId ?? "none")
        """)
    }

    func stop() {
        guard isRecording else { return }
        Maple.stop()
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
