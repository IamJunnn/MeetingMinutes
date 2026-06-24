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

    private let modelManager = WhisperModelManager()

    var isWorking: Bool {
        switch phase {
        case .downloadingModel, .transcribing: return true
        default: return false
        }
    }

    func transcribe(folder: URL) async {
        lines = []
        do {
            let provider = TranscriptionSettings.provider
            let transcriber = try await makeTranscriber(for: provider)

            let fm = FileManager.default
            let micURL = folder.appendingPathComponent("mic.m4a")
            let systemURL = folder.appendingPathComponent("system.m4a")

            var merged: [TranscriptLine] = []
            phase = .transcribing(0)

            // "You" track (mic) covers the first half of the progress bar, the
            // participant track (system audio) the second half. The participant
            // track is diarized when the engine supports it, splitting the mixed
            // remote audio into "Speaker 1", "Speaker 2", …
            if fm.fileExists(atPath: micURL.path) {
                merged += try await transcriber.transcribe(audioURL: micURL, speaker: "You", diarize: false) { fraction in
                    Task { @MainActor in self.phase = .transcribing(fraction * 0.5) }
                }
            }
            if fm.fileExists(atPath: systemURL.path) {
                let label = provider.diarizes ? "Speaker" : "Participant"
                merged += try await transcriber.transcribe(audioURL: systemURL, speaker: label, diarize: provider.diarizes) { fraction in
                    Task { @MainActor in self.phase = .transcribing(0.5 + fraction * 0.5) }
                }
            }

            merged.sort { $0.start < $1.start }
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

    /// Build the transcriber for the chosen provider, downloading the whisper
    /// model first for the local engine (Deepgram needs no model).
    private func makeTranscriber(for provider: TranscriptionProvider) async throws -> Transcriber {
        switch provider {
        case .local:
            phase = .downloadingModel(modelManager.isModelDownloaded ? 1 : 0)
            let modelURL = try await modelManager.ensureModel { fraction in
                Task { @MainActor in self.phase = .downloadingModel(fraction) }
            }
            return LocalWhisperTranscriber(modelURL: modelURL)
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

    private func write(_ lines: [TranscriptLine], to folder: URL) throws {
        try lines.plainText.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lines)
        try data.write(to: folder.appendingPathComponent("transcript.json"))
    }
}
