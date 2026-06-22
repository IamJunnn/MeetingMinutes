import SwiftUI

struct RecordingView: View {
    @StateObject private var controller = RecordingController()
    @StateObject private var transcription = TranscriptionService()
    @StateObject private var minutes = MinutesService()
    @StateObject private var permissions = PermissionsManager()
    @State private var showSettings = false
    @State private var showPermissions = false

    var body: some View {
        VStack(spacing: 24) {
            header
            timeDisplay
            recordButton
            statusFooter
            transcriptionSection
            minutesSection
        }
        .padding(40)
        .frame(width: 480)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPermissions) {
            PermissionsView(permissions: permissions) { showPermissions = false }
        }
        .onAppear {
            permissions.refresh()
            showPermissions = !permissions.allGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    private var header: some View {
        VStack(spacing: 4) {
            HStack {
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .help("Settings")
            }
            Text("Meeting Minutes")
                .font(.largeTitle.bold())
            Text("Records your mic and the meeting's audio on separate tracks.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var recordButton: some View {
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
        case .finishing:
            Label("Finishing recording…", systemImage: "hourglass")
                .font(.callout)
                .foregroundStyle(.secondary)
        default:
            if controller.lastRecordingFolder == nil {
                Text("Press Start to begin. You'll be asked for Microphone and Screen Recording permission the first time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Transcription

    @ViewBuilder
    private var transcriptionSection: some View {
        if let folder = controller.lastRecordingFolder, !controller.isRecording {
            Divider()

            HStack {
                Button {
                    Task { await transcription.transcribe(folder: folder) }
                } label: {
                    Label("Transcribe", systemImage: "text.bubble")
                }
                .disabled(transcription.isWorking)

                Spacer()

                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                .buttonStyle(.link)
            }

            transcriptionStatus

            if !transcription.lines.isEmpty {
                TranscriptListView(lines: transcription.lines)
                    .frame(height: 220)
            }
        }
    }

    @ViewBuilder
    private var transcriptionStatus: some View {
        switch transcription.phase {
        case .downloadingModel(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("Downloading transcription model (one time, ~466 MB)…")
                    .font(.footnote).foregroundStyle(.secondary)
                ProgressView(value: fraction)
            }
        case .transcribing(let fraction):
            VStack(alignment: .leading, spacing: 4) {
                Text("Transcribing…")
                    .font(.footnote).foregroundStyle(.secondary)
                ProgressView(value: fraction)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .completed where transcription.lines.isEmpty:
            Text("No speech detected in this recording.")
                .font(.footnote).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Minutes

    @ViewBuilder
    private var minutesSection: some View {
        if !transcription.lines.isEmpty, let folder = controller.lastRecordingFolder {
            Divider()

            HStack {
                Button {
                    Task { await minutes.generate(from: transcription.lines, folder: folder) }
                } label: {
                    Label("Generate Minutes", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(minutes.isGenerating)

                Spacer()

                if case .completed = minutes.phase {
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(minutes.markdown, forType: .string)
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.link)
                }
            }

            minutesStatus
        }
    }

    @ViewBuilder
    private var minutesStatus: some View {
        switch minutes.phase {
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating minutes with Claude…")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .completed:
            ScrollView {
                MarkdownView(markdown: minutes.markdown)
                    .textSelection(.enabled)
                    .padding(12)
            }
            .frame(height: 260)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
        case .idle:
            EmptyView()
        }
    }

    private static func format(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

/// Scrollable, color-coded transcript.
private struct TranscriptListView: View {
    let lines: [TranscriptLine]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(line.speaker)
                                .font(.caption.bold())
                                .foregroundStyle(line.speaker == "You" ? Color.accentColor : Color.orange)
                            Text(line.timestamp)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(line.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}

#Preview {
    RecordingView()
}
