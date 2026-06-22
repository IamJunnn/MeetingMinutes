import SwiftUI

/// Detail pane for a past meeting: play its audio, read the transcript, and
/// view (or generate) the minutes. Reuses the transcription and minutes
/// services so recordings that weren't processed yet can be completed here.
struct MeetingDetailView: View {
    let meeting: Meeting
    var onChanged: () -> Void

    @StateObject private var transcription = TranscriptionService()
    @StateObject private var minutes = MinutesService()
    @StateObject private var player = AudioPlayer()

    @State private var lines: [TranscriptLine] = []
    @State private var minutesMarkdown: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerRow
                audioSection
                Divider()
                transcriptSection
                Divider()
                minutesSection
            }
            .padding(24)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: meeting.id) { await load() }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(meeting.title).font(.title2.bold())
            Spacer()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
            }
            .buttonStyle(.link)
        }
    }

    // MARK: - Audio

    private var audioSection: some View {
        HStack(spacing: 12) {
            Button(action: player.togglePlay) {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 32))
            }
            .buttonStyle(.borderless)
            .disabled(player.loadedURL == nil)

            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0...max(player.duration, 0.1)
            )
            .disabled(player.loadedURL == nil)

            Text("\(Self.time(player.currentTime)) / \(Self.time(player.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transcript

    @ViewBuilder
    private var transcriptSection: some View {
        HStack {
            Text("Transcript").font(.headline)
            Spacer()
            if !transcription.isWorking {
                Button(lines.isEmpty ? "Transcribe" : "Re-transcribe") {
                    Task {
                        await transcription.transcribe(folder: meeting.folder)
                        lines = transcription.lines
                        onChanged()
                    }
                }
            }
        }

        switch transcription.phase {
        case .downloadingModel(let fraction):
            labeledProgress("Downloading transcription model (one time, ~466 MB)…", fraction)
        case .transcribing(let fraction):
            labeledProgress("Transcribing…", fraction)
        case .failed(let message):
            errorLabel(message)
        default:
            if lines.isEmpty {
                Text("Not transcribed yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                TranscriptListView(lines: lines).frame(height: 280)
            }
        }
    }

    // MARK: - Minutes

    @ViewBuilder
    private var minutesSection: some View {
        HStack {
            Text("Minutes").font(.headline)
            Spacer()
            if case .completed = minutes.phase, !minutesMarkdown.isEmpty {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(minutesMarkdown, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.link)
            }
            if !minutes.isGenerating && !lines.isEmpty {
                Button(minutesMarkdown.isEmpty ? "Generate Minutes" : "Regenerate") {
                    Task {
                        await minutes.generate(from: lines, folder: meeting.folder)
                        if case .completed = minutes.phase { minutesMarkdown = minutes.markdown }
                        onChanged()
                    }
                }
            }
        }

        switch minutes.phase {
        case .generating:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Generating minutes with Claude…").font(.footnote).foregroundStyle(.secondary)
            }
        case .failed(let message):
            errorLabel(message)
        default:
            if minutesMarkdown.isEmpty {
                Text(lines.isEmpty ? "Transcribe first, then generate minutes." : "No minutes yet.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                MarkdownView(markdown: minutesMarkdown)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            }
        }
    }

    // MARK: - Helpers

    private func load() async {
        lines = meeting.loadTranscript()
        minutesMarkdown = meeting.loadMinutes()
        if let url = await AudioMixer.mixedURL(for: meeting) {
            player.load(url)
        }
    }

    private func labeledProgress(_ text: String, _ fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.footnote).foregroundStyle(.secondary)
            ProgressView(value: fraction)
        }
    }

    private func errorLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote).foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func time(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
