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
    @State private var speakerNames: [String: String] = [:]
    @State private var minutesMarkdown: String = ""
    @State private var isEditingMinutes = false
    @State private var minutesDraft = ""
    @State private var copied = false

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
                        speakerNames = meeting.loadSpeakerNames()   // AI may have named the speakers
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
                speakerEditor
                TranscriptListView(lines: lines, names: speakerNames).frame(height: 280)
            }
        }
    }

    /// The distinct diarized speaker labels ("Speaker 1", "Speaker 2", …),
    /// ordered by their number. Empty for on-device transcripts.
    private var diarizedSpeakers: [String] {
        let labels = Set(lines.map(\.speaker)).filter { $0.hasPrefix("Speaker ") }
        return labels.sorted { lhs, rhs in
            (Int(lhs.split(separator: " ").last ?? "") ?? 0) < (Int(rhs.split(separator: " ").last ?? "") ?? 0)
        }
    }

    /// Inline editor for naming the diarized speakers. AI fills these in from
    /// the conversation; the user corrects anything wrong. Saved on each edit.
    @ViewBuilder
    private var speakerEditor: some View {
        if !diarizedSpeakers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Speakers")
                    .font(.subheadline.bold())
                Text("AI guesses names from the conversation — fix any it got wrong.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(diarizedSpeakers, id: \.self) { label in
                    HStack(spacing: 8) {
                        Circle().fill(SpeakerColor.color(for: label)).frame(width: 9, height: 9)
                        Text(label)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        TextField("Name", text: speakerNameBinding(for: label))
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 220)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    /// Two-way binding to a speaker's display name, persisting every change to
    /// `speakers.json` so renames survive relaunches.
    private func speakerNameBinding(for label: String) -> Binding<String> {
        Binding(
            get: { speakerNames[label] ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { speakerNames.removeValue(forKey: label) }
                else { speakerNames[label] = trimmed }
                SpeakerNamesStore.save(speakerNames, in: meeting.folder)
                onChanged()
            }
        )
    }

    // MARK: - Minutes

    @ViewBuilder
    private var minutesSection: some View {
        HStack {
            Text("Minutes").font(.headline)
            Spacer()
            if isEditingMinutes {
                Button("Cancel") { isEditingMinutes = false }
                    .buttonStyle(.link)
                Button("Save", action: saveEditedMinutes)
                    .buttonStyle(.link)
            } else {
                if !minutesMarkdown.isEmpty {
                    Button { startEditingMinutes() } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .buttonStyle(.link)

                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(exportText, forType: .string)
                        copied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied!" : "Copy",
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copied ? Color.green : Color.accentColor)
                    }
                    .buttonStyle(.link)

                    ShareLink(item: exportText, subject: Text("Meeting Minutes — \(meeting.title)")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.link)
                }
                if !minutes.isGenerating && !lines.isEmpty {
                    Button(minutesMarkdown.isEmpty ? "Generate Minutes" : "Regenerate") {
                        Task {
                            await minutes.generate(from: namedLines, folder: meeting.folder)
                            if case .completed = minutes.phase { minutesMarkdown = minutes.markdown }
                            onChanged()
                        }
                    }
                }
            }
        }

        if isEditingMinutes {
            minutesEditor
        } else {
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
    }

    /// Raw-Markdown editor shown when correcting the minutes by hand.
    private var minutesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $minutesDraft)
                .font(.system(.callout, design: .monospaced))
                .frame(minHeight: 260)
                .padding(8)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
            Text("Edit the Markdown directly — `##` headings, `-` bullets, `**bold**`.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func startEditingMinutes() {
        minutesDraft = minutesMarkdown
        isEditingMinutes = true
    }

    /// Persist the hand-edited minutes back to `minutes.md` and re-render.
    private func saveEditedMinutes() {
        minutesMarkdown = minutesDraft
        try? minutesMarkdown.write(to: meeting.minutesURL, atomically: true, encoding: .utf8)
        isEditingMinutes = false
        onChanged()
    }

    // MARK: - Helpers

    /// Clean, email-ready text: the meeting date followed by the minutes with
    /// Markdown symbols stripped.
    private var exportText: String {
        meeting.title + "\n\n" + MinutesExport.plainText(minutesMarkdown)
    }

    /// Transcript with canonical speaker labels swapped for their display names,
    /// so the generated minutes refer to people by name rather than "Speaker 2".
    private var namedLines: [TranscriptLine] {
        guard !speakerNames.isEmpty else { return lines }
        return lines.map { line in
            guard let name = speakerNames[line.speaker] else { return line }
            return TranscriptLine(speaker: name, start: line.start, end: line.end, text: line.text)
        }
    }

    private func load() async {
        lines = meeting.loadTranscript()
        speakerNames = meeting.loadSpeakerNames()
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
