import Maple
import SwiftUI
import UIKit

/// Launch-environment switches for the XCUITest suite in `UITests/`.
///
/// Only read when `MAPLE_E2E=1`, which nothing but the UI test runner sets, so the
/// ordinary demo is unaffected.
enum E2EConfiguration {
    private static var environment: [String: String] { ProcessInfo.processInfo.environment }

    static var isEnabled: Bool { environment["MAPLE_E2E"] == "1" }

    /// Rotation is portrait-only outside the rotation scenario, so a stray device
    /// orientation cannot reshape the frames every other scenario measures.
    static var allowsRotation: Bool { isEnabled && environment["MAPLE_E2E_ROTATION"] == "1" }

    static var options: MapleOptions {
        var options = MapleOptions()
        options.ingestKey = environment["MAPLE_INGEST_KEY"]
        options.endpoint = environment["MAPLE_ENDPOINT"].flatMap(URL.init(string:))
        options.serviceName = "replay-demo-e2e"
        options.environment = "e2e"

        var replay = ReplayOptions()
        replay.frameRate = int("MAPLE_FRAME_RATE") ?? 2
        replay.segmentDuration = double("MAPLE_SEGMENT_DURATION") ?? 2
        replay.sessionSampleRate = double("MAPLE_SESSION_SAMPLE_RATE") ?? 1
        replay.onErrorSampleRate = double("MAPLE_ON_ERROR_SAMPLE_RATE") ?? 0
        replay.errorBufferWindow = double("MAPLE_ERROR_BUFFER_WINDOW") ?? 30
        replay.backgroundSessionTimeout = double("MAPLE_BACKGROUND_TIMEOUT") ?? 30
        // Lets a run prove the masking assertions can fail.
        replay.maskAllText = environment["MAPLE_MASK_ALL_TEXT"] != "0"
        options.replay = replay
        return options
    }

    /// Start the SDK the way a host app would, after clearing what earlier launches left.
    ///
    /// The runner kills the app between tests, which leaves a crash-recovery spool behind;
    /// without the reset the next test would receive the previous test's recovered segment.
    @MainActor
    static func startIfEnabled() {
        guard isEnabled else { return }
        if environment["MAPLE_E2E_RESET"] == "1" {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: caches.appendingPathComponent("maple-replay"))
        }
        Maple.start(options: options)
    }

    private static func double(_ key: String) -> Double? { environment[key].flatMap(Double.init) }
    private static func int(_ key: String) -> Int? { environment[key].flatMap(Int.init) }
}

/// Fixed-layout screen the UI tests measure against. Every element the suite locates has
/// an accessibility identifier; the geometry is read from the live app, never hardcoded.
struct E2EScreen: View {
    @State private var name = ""
    @State private var password = ""
    @State private var keyPresses = 0
    @State private var tracked = 0
    @State private var userSet = false

    var body: some View {
        ZStack {
            SolidColorView(color: UIColor(white: 0.85, alpha: 1), identifier: "e2e.background")
                .ignoresSafeArea()

            VStack(spacing: 14) {
                // No padding or background: the element's frame must be the glyphs' frame,
                // which is what the masking scenario expects to find painted black.
                Text("SECRET-4242-PII")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.black)
                    .accessibilityIdentifier("e2e.secret")

                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("e2e.textField")
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("e2e.secureField")

                // A UIKit view that paints only `backgroundColor`, so the scanner treats it
                // as unmasked: the control region the masking scenario compares against.
                SolidColorView(color: UIColor(red: 1, green: 0, blue: 1, alpha: 1), identifier: "e2e.plain")
                    .frame(width: 160, height: 90)

                keypad
                    .mapleReplayMask()

                Text("keys \(keyPresses) tracked \(tracked) user \(userSet ? "set" : "none")")
                    .font(.caption.monospaced())
                    .accessibilityIdentifier("e2e.status")

                HStack(spacing: 8) {
                    action("Error", id: "e2e.triggerError") { MapleReplay.shared.flush(trigger: "error") }
                    action("User", id: "e2e.setUser") {
                        Maple.setUserId("user-42")
                        userSet = true
                    }
                    action("Track", id: "e2e.track") {
                        Maple.track("e2e_button_tapped", properties: ["source": "e2e"])
                        tracked += 1
                    }
                    action("Crash", id: "e2e.crash") { abort() }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
        }
    }

    private var keypad: some View {
        VStack(spacing: 6) {
            ForEach(0..<3) { row in
                HStack(spacing: 6) {
                    ForEach(1...3, id: \.self) { column in
                        let digit = row * 3 + column
                        Button("\(digit)") { keyPresses += 1 }
                            .font(.title2)
                            .frame(width: 64, height: 44)
                            .background(Color.blue.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                            .accessibilityIdentifier("e2e.key.\(digit)")
                    }
                }
            }
        }
        .padding(8)
    }

    private func action(_ title: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(title, action: perform)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(id)
    }
}

/// A plain `UIView` with a background colour and nothing else.
private struct SolidColorView: UIViewRepresentable {
    let color: UIColor
    let identifier: String

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = color
        view.isAccessibilityElement = true
        view.accessibilityIdentifier = identifier
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Portrait unless the rotation scenario asked otherwise. The plist lists landscape so
/// this delegate has something to narrow.
final class DemoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        E2EConfiguration.allowsRotation ? .allButUpsideDown : .portrait
    }
}
