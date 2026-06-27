import Foundation

/// A source of transcripts for a single audio track. Implemented locally by
/// `LocalWhisperTranscriber` and in the cloud by `DeepgramTranscriber` (which
/// adds per-person diarization).
protocol Transcriber {
    /// Transcribe one audio file.
    /// - Parameters:
    ///   - speaker: base label for produced lines. With `diarize` off, every
    ///     line gets exactly this label (e.g. "You"). With `diarize` on it's a
    ///     prefix and lines split per detected voice ("Speaker 1", "Speaker 2"…).
    ///   - diarize: request per-person speaker separation. Engines that can't
    ///     diarize (whisper.cpp) ignore it and label every line `speaker`.
    func transcribe(audioURL: URL, speaker: String, diarize: Bool, progress: @escaping (Double) -> Void) async throws -> [TranscriptLine]
}
