import AVFoundation
import Foundation

/// Drives transcription for a recording session: makes sure the model is
/// present, transcribes each track, merges them into a single time-ordered
/// transcript, and writes the result alongside the audio.
@MainActor
final class TranscriptionService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloadingModel(Double)
        case transcribing(Double)
        case completed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lines: [TranscriptLine] = []
    /// Non-fatal problem with the last run, e.g. a track that had to be
    /// skipped because its file was unreadable.
    @Published private(set) var warning: String?

    private let modelManager = WhisperModelManager()

    var isWorking: Bool {
        switch phase {
        case .downloadingModel, .transcribing: return true
        default: return false
        }
    }

    func transcribe(folder: URL) async {
        lines = []
        warning = nil
        do {
            let provider = TranscriptionSettings.provider
            let transcriber = try await makeTranscriber(for: provider)

            let fm = FileManager.default
            let systemURL = folder.appendingPathComponent("system.m4a")

            var merged: [TranscriptLine] = []
            phase = .transcribing(0)

            // Use the echo-cancelled mic when speaker bleed was found (cached;
            // computed on first use) so the participants' voices leaking into
            // the mic aren't transcribed as phantom "You" lines.
            let micURL = await EchoCanceller.shared.cleanedMicURL(in: folder)

            // Each track's timestamps are relative to its own file, but the
            // tracks start at different moments — shift the later one so the
            // merged transcript shares a single timeline.
            let offset = EchoCanceller.alignment(in: folder)?.systemOffsetSeconds ?? 0
            let micShift = max(0, -offset)
            let systemShift = max(0, offset)

            // "You" track (mic) covers the first half of the progress bar, the
            // participant track (system audio) the second half. The participant
            // track is diarized when the engine supports it, splitting the mixed
            // remote audio into "Speaker 1", "Speaker 2", …
            // A track whose file can't be decoded (e.g. a recording that was
            // cut off before the file was finalized) is skipped with a warning
            // rather than failing the whole run on a cryptic decoder error.
            var skipped: [String] = []
            var transcribedAnything = false

            if fm.fileExists(atPath: micURL.path) {
                if await Self.isReadable(micURL) {
                    let micLines = try await transcriber.transcribe(audioURL: micURL, speaker: "You", diarize: false) { fraction in
                        Task { @MainActor in self.phase = .transcribing(fraction * 0.5) }
                    }
                    merged += Self.shifted(micLines, by: micShift)
                    transcribedAnything = true
                } else {
                    skipped.append("your microphone track (\(micURL.lastPathComponent))")
                }
            }
            if fm.fileExists(atPath: systemURL.path) {
                if await Self.isReadable(systemURL) {
                    let label = provider.diarizes ? "Speaker" : "Participant"
                    let systemLines = try await transcriber.transcribe(audioURL: systemURL, speaker: label, diarize: provider.diarizes) { fraction in
                        Task { @MainActor in self.phase = .transcribing(0.5 + fraction * 0.5) }
                    }
                    merged += Self.shifted(systemLines, by: systemShift)
                    transcribedAnything = true
                } else {
                    skipped.append("the participants' track (system.m4a)")
                }
            }

            guard transcribedAnything else { throw TranscriptionError.noReadableAudio }
            if !skipped.isEmpty {
                warning = "Skipped \(skipped.joined(separator: " and ")): the file is damaged and can't be decoded — usually a recording that was cut off before it finished."
            }

            merged.sort { $0.start < $1.start }
            // Shared cleanup: whisper's silence loops dropped, mic bleed that survived the echo canceller removed,
            // and the per-breath fragments joined into paragraphs instead of a column of two second lines.
            merged = TranscriptCleanup.cleaned(merged)
            lines = merged
            try write(merged, to: folder)

            // Diarization gives anonymous "Speaker N" labels — try to name them
            // from the conversation. Best-effort: never blocks completion.
            if provider.diarizes {
                await inferSpeakerNames(for: merged, in: folder)
            }

            phase = .completed
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    enum TranscriptionError: LocalizedError {
        case noReadableAudio
        var errorDescription: String? {
            "None of this meeting's audio files can be decoded — the recording was cut off before the files were finalized."
        }
    }

    /// Whether the file opens as audio with a real duration. Rejects the
    /// unfinalized files a cut-off recording leaves behind before they're
    /// uploaded or fed to the local model.
    private static func isReadable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds > 0
    }

    /// Build the transcriber for the chosen provider, downloading the whisper
    /// model first for the local engine (Deepgram needs no model).
    private func makeTranscriber(for provider: TranscriptionProvider) async throws -> Transcriber {
        switch provider {
        case .local:
            phase = .downloadingModel(0)
            // CodeSwitchTranscriber rather than LocalWhisperTranscriber: whisper picks a language once, from the
            // first thirty seconds of whatever it is handed, and keeps it for the rest of the file. On a meeting that
            // opened in Korean and turned to English that cost 53 of its 74 minutes, replaced by one invented phrase
            // repeated 1,613 times. This one feeds the audio in two minute chunks so the language is detected again
            // and again. WhisperChoice also defaults to a stronger model than ggml-small.
            let (modelURL, note) = try await WhisperChoice.ensure { fraction in
                Task { @MainActor in self.phase = .downloadingModel(fraction) }
            }
            if let note { warning = note }
            return CodeSwitchTranscriber(modelURL: modelURL)
        case .deepgram:
            guard let key = KeychainStore.load(account: provider.keychainAccount), !key.isEmpty else {
                throw LLMError.missingKey(provider: "Deepgram")
            }
            return DeepgramTranscriber(apiKey: key)
        }
    }

    /// Ask the active LLM to name the diarized speakers and persist the result.
    /// Silently does nothing if no LLM is configured or nothing was identified.
    private func inferSpeakerNames(for lines: [TranscriptLine], in folder: URL) async {
        let labels = Set(lines.map(\.speaker)).filter { $0.hasPrefix("Speaker ") }
        guard !labels.isEmpty, let client = try? LLMClientFactory.makeActive() else { return }
        guard let names = try? await SpeakerNamer.inferNames(from: lines, labels: labels, using: client),
              !names.isEmpty else { return }
        SpeakerNamesStore.save(names, in: folder)
    }

    /// The same lines moved later by `offset` seconds (no-op for zero).
    private static func shifted(_ lines: [TranscriptLine], by offset: TimeInterval) -> [TranscriptLine] {
        guard offset > 0 else { return lines }
        return lines.map {
            TranscriptLine(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset, text: $0.text)
        }
    }


    private func write(_ lines: [TranscriptLine], to folder: URL) throws {
        try lines.plainText.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lines)
        try data.write(to: folder.appendingPathComponent("transcript.json"))
    }
}
