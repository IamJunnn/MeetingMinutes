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
            phase = .downloadingModel(modelManager.isModelDownloaded ? 1 : 0)
            let modelURL = try await modelManager.ensureModel { fraction in
                Task { @MainActor in self.phase = .downloadingModel(fraction) }
            }

            let transcriber = LocalWhisperTranscriber(modelURL: modelURL)
            let fm = FileManager.default
            let micURL = folder.appendingPathComponent("mic.m4a")
            let systemURL = folder.appendingPathComponent("system.m4a")

            var merged: [TranscriptLine] = []
            phase = .transcribing(0)

            // "You" track (mic) covers the first half of the progress bar, the
            // "Participant" track (system audio) the second half.
            if fm.fileExists(atPath: micURL.path) {
                merged += try await transcriber.transcribe(audioURL: micURL, speaker: "You") { fraction in
                    Task { @MainActor in self.phase = .transcribing(fraction * 0.5) }
                }
            }
            if fm.fileExists(atPath: systemURL.path) {
                merged += try await transcriber.transcribe(audioURL: systemURL, speaker: "Participant") { fraction in
                    Task { @MainActor in self.phase = .transcribing(0.5 + fraction * 0.5) }
                }
            }

            merged.sort { $0.start < $1.start }
            lines = merged
            try write(merged, to: folder)
            phase = .completed
        } catch {
            phase = .failed(error.localizedDescription)
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
