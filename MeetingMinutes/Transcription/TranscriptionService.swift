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
            if fm.fileExists(atPath: micURL.path) {
                let micLines = try await transcriber.transcribe(audioURL: micURL, speaker: "You", diarize: false) { fraction in
                    Task { @MainActor in self.phase = .transcribing(fraction * 0.5) }
                }
                merged += Self.shifted(micLines, by: micShift)
            }
            if fm.fileExists(atPath: systemURL.path) {
                let label = provider.diarizes ? "Speaker" : "Participant"
                let systemLines = try await transcriber.transcribe(audioURL: systemURL, speaker: label, diarize: provider.diarizes) { fraction in
                    Task { @MainActor in self.phase = .transcribing(0.5 + fraction * 0.5) }
                }
                merged += Self.shifted(systemLines, by: systemShift)
            }

            merged.sort { $0.start < $1.start }
            merged = Self.removingEcho(from: merged)
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

    /// The same lines moved later by `offset` seconds (no-op for zero).
    private static func shifted(_ lines: [TranscriptLine], by offset: TimeInterval) -> [TranscriptLine] {
        guard offset > 0 else { return lines }
        return lines.map {
            TranscriptLine(speaker: $0.speaker, start: $0.start + offset, end: $0.end + offset, text: $0.text)
        }
    }

    // MARK: - Echo removal

    /// Drop mic ("You") segments that are really the participants' audio echoing
    /// back through the speakers into the microphone. When a "You" line overlaps
    /// in time with a participant line and shares most of its words, the "You"
    /// copy is acoustic bleed, not the user — so we discard it. A text-level
    /// backstop behind EchoCanceller's audio-level cleanup.
    private static func removingEcho(from lines: [TranscriptLine]) -> [TranscriptLine] {
        let participantLines = lines.filter { $0.speaker != "You" }
        guard !participantLines.isEmpty else { return lines }
        return lines.filter { line in
            guard line.speaker == "You" else { return true }
            return !participantLines.contains { other in
                overlapsInTime(line, other) && sharesMostWords(line.text, other.text)
            }
        }
    }

    /// True when two segments' time spans overlap, allowing 1s of slack for the
    /// small delay between speaker output and the mic picking it back up.
    private static func overlapsInTime(_ a: TranscriptLine, _ b: TranscriptLine, slack: TimeInterval = 1) -> Bool {
        a.start < b.end + slack && b.start < a.end + slack
    }

    /// True when ≥60% of the shorter segment's words appear in the longer one.
    /// Containment (not Jaccard) on purpose: an echoed "You" line is often
    /// padded with extra ASR filler, so the participant line is a subset of it.
    private static func sharesMostWords(_ x: String, _ y: String, threshold: Double = 0.6) -> Bool {
        let sx = Set(x.split(separator: " "))
        let sy = Set(y.split(separator: " "))
        let shorter = sx.count <= sy.count ? sx : sy
        let longer = sx.count <= sy.count ? sy : sx
        guard shorter.count >= 2 else { return false }
        let overlap = shorter.intersection(longer).count
        return Double(overlap) / Double(shorter.count) >= threshold
    }

    private func write(_ lines: [TranscriptLine], to folder: URL) throws {
        try lines.plainText.write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(lines)
        try data.write(to: folder.appendingPathComponent("transcript.json"))
    }
}
