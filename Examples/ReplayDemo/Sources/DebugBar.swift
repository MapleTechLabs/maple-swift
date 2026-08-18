import Maple
import SwiftUI

struct DebugBar: View {
    @ObservedObject var controller: RecorderController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(controller.isRecording ? "Stop" : "Record") {
                    controller.isRecording ? controller.stop() : controller.start()
                }
                .buttonStyle(.borderedProminent)
                .tint(controller.isRecording ? .red : .accentColor)

                Button("Trigger error") { controller.triggerError() }
                    .buttonStyle(.bordered)
                    .disabled(!controller.isRecording)

                Spacer()

                Toggle(isOn: $controller.showMaskPreview) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                }
                .toggleStyle(.button)
            }

            Picker("Mode", selection: $controller.mode) {
                ForEach(RecorderController.Mode.allCases) { mode in
                    Text(mode.rawValue.capitalized).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            // Changing the policy rebuilds the ring buffer, so it can only be chosen
            // before recording starts.
            .disabled(controller.isRecording)

            Picker("Quality", selection: $controller.quality) {
                ForEach(ReplayQuality.allCases, id: \.self) { quality in
                    Text(quality.rawValue.capitalized).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isRecording)

            summary
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    /// Segment sizes are the point of this readout: they decide whether carrying the MP4
    /// as base64 inside the JSON chunk is viable, which is the open question for the
    /// upload milestone.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let last = controller.segments.last {
                Text("segment \(last.chunkSeq) · \(last.frameCount) frames · \(last.durationMs) ms")
                    .font(.caption2.monospaced())
                Text("mp4 \(byteLabel(last.videoBytes)) · chunk gz \(byteLabel(last.gzippedBytes))")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                Text(controller.isRecording ? "recording — no segment yet" : "idle")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            Text("\(controller.segments.count) segments · total gz \(byteLabel(totalGzipped))")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var totalGzipped: Int {
        controller.segments.reduce(0) { $0 + $1.gzippedBytes }
    }

    private func byteLabel(_ bytes: Int) -> String {
        bytes < 1_024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1_024)
    }
}

/// Bridges the SDK's debug overlay into SwiftUI.
struct MaskPreviewOverlay: UIViewRepresentable {
    let options: ReplayOptions

    func makeUIView(context: Context) -> MaskingPreviewView {
        MaskingPreviewView(options: options)
    }

    func updateUIView(_ view: MaskingPreviewView, context: Context) {}
}
