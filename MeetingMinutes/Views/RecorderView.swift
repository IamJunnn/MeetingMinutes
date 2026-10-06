import SwiftUI

/// The "New Recording" pane: live record controls only. The controller is the
/// app-wide `RecordingController.shared`, owned by ContentView — this pane can
/// come and go with sidebar navigation without touching a live recording.
struct RecorderView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(spacing: 4) {
                Text("New Recording")
                    .font(.largeTitle.bold())
                Text("Captures your mic and the meeting's audio together.")
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

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var timeDisplay: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(controller.isRecording ? .red : .secondary.opacity(0.4))
                .frame(width: 12, height: 12)
            Text(RecordingController.clockString(controller.elapsed))
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
            VStack(spacing: 6) {
                Label("Recording… capturing microphone and system audio.", systemImage: "waveform")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if controller.silenceSeconds >= 60 {
                    let remaining = max(0, RecordingController.silenceTimeout - controller.silenceSeconds)
                    Label("No audio for \(Int(controller.silenceSeconds / 60)) min — stopping automatically in \(RecordingController.clockString(remaining)).",
                          systemImage: "moon.zzz")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            }
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
            VStack(spacing: 6) {
                if controller.lastStopReason == .silence {
                    Label("The last recording stopped by itself after \(Int(RecordingController.silenceTimeout / 60)) minutes of silence.",
                          systemImage: "moon.zzz")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Text("Press Start to begin. You'll be asked for Microphone and Screen Recording permission the first time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
        }
    }
}
