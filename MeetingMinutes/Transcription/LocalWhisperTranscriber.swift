import Foundation
import SwiftWhisper

/// Transcribes audio on-device with whisper.cpp (via SwiftWhisper). Free,
/// private, offline. Language defaults to auto-detect for multilingual support.
final class LocalWhisperTranscriber: Transcriber {
    private let modelURL: URL
    private let language: WhisperLanguage

    init(modelURL: URL, language: WhisperLanguage = .auto) {
        self.modelURL = modelURL
        self.language = language
    }

    /// Number of performance (high-power) cores, used to size whisper's thread
    /// pool. Falls back to the total active core count on non-Apple-Silicon or
    /// if the perf-level sysctl is unavailable.
    private static var performanceCoreCount: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 {
            return Int(count)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    /// whisper.cpp can't diarize, so `diarize` is ignored — every line is
    /// labeled `speaker`.
    func transcribe(audioURL: URL, speaker: String, diarize: Bool = false, progress: @escaping (Double) -> Void) async throws -> [TranscriptLine] {
        // Decode + resample off the main thread; this is CPU/IO heavy.
        let frames = try await Task.detached(priority: .userInitiated) {
            try AudioDecoder.decodeTo16kMonoFloat(url: audioURL)
        }.value

        guard !frames.isEmpty else { return [] }

        let params = WhisperParams.default
        params.language = language
        // whisper.cpp defaults to min(4, cores). Use the *performance* cores
        // only: piling whisper onto the efficiency cores makes the fast cores
        // wait on the slow ones, so all-cores is usually slower than P-cores.
        params.n_threads = Int32(Self.performanceCoreCount)
        let whisper = Whisper(fromFileURL: modelURL, withParams: params)

        let delegate = ProgressDelegate(onProgress: progress)
        whisper.delegate = delegate

        let segments = try await whisper.transcribe(audioFrames: frames)

        return segments.compactMap { segment in
            let text = segment.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .collapsingRepeatedTokens()
            guard !text.isEmpty, !Self.isNonSpeech(text) else { return nil }
            return TranscriptLine(
                speaker: speaker,
                start: Double(segment.startTime) / 1000,   // SwiftWhisper reports ms
                end: Double(segment.endTime) / 1000,
                text: text
            )
        }
    }

    /// whisper.cpp emits non-speech annotations for silence/music/noise, e.g.
    /// `[BLANK_AUDIO]`, `[Music]`, `(silence)`. These are entirely wrapped in
    /// brackets or parentheses; drop them so the transcript stays clean.
    private static func isNonSpeech(_ text: String) -> Bool {
        (text.hasPrefix("[") && text.hasSuffix("]") && !text.dropFirst().dropLast().contains("[")) ||
        (text.hasPrefix("(") && text.hasSuffix(")") && !text.dropFirst().dropLast().contains("("))
    }

    /// Bridges SwiftWhisper's delegate progress callbacks to a closure.
    private final class ProgressDelegate: WhisperDelegate {
        let onProgress: (Double) -> Void
        init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }

        func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
            onProgress(progress)
        }
    }
}
