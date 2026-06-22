import Foundation

/// A source of transcripts for a single audio track. Implemented locally by
/// `LocalWhisperTranscriber`; a cloud provider can be added later behind the
/// same interface (e.g. for per-person diarization).
protocol Transcriber {
    /// Transcribe one audio file. `speaker` labels every produced line.
    func transcribe(audioURL: URL, speaker: String, progress: @escaping (Double) -> Void) async throws -> [TranscriptLine]
}
