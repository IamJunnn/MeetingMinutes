import SwiftUI

/// The "New Recording" pane: live record controls only. When a recording
/// finishes, `onFinished` is called with its folder so the library can refresh
/// and select it.
struct RecorderView: View {
    var onFinished: (URL) -> Void

    @StateObject private var controller = RecordingController()

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 4) {
                Text("New Recording")
                    .font(.largeTitle.bold())
                Text("Records your mic and the meeting's audio on separate tracks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            timeDisplay

            Button(action: controller.toggle) {
                Label(controller.isRecording ? "Stop Recording" : "Start Recording",
                      systemImage: controller.isRecording ? "stop.circle.fill" : "record.circle")
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(controller.isRecording ? .red : .accentColor)
            .disabled(controller.isBusy)
            .frame(maxWidth: 360)

            statusFooter
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: controller.lastRecordingFolder) { _, newValue in
            if let folder = newValue { onFinished(folder) }
        }
    }

    private var timeDisplay: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.isRecording ? .red : .secondary.opacity(0.4))
                .frame(width: 12, height: 12)
            Text(Self.format(controller.elapsed))
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(height: 60)
    }

    @ViewBuilder
    private var statusFooter: some View {
        switch controller.state {
        case .recording:
            Label("Recording… capturing microphone and system audio.", systemImage: "waveform")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        case .finishing:
            Label("Finishing recording…", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        default:
            Text("Press Start to begin. You'll be asked for Microphone and Screen Recording permission the first time.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}
