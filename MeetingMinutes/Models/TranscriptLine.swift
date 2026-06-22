import Foundation

/// One labeled line of a meeting transcript. Speaker attribution comes for free
/// from which track the audio was on: the mic track is "You", the system-audio
/// track is "Participant".
struct TranscriptLine: Identifiable, Codable, Equatable {
    var id = UUID()
    let speaker: String
    let start: TimeInterval   // seconds from the start of the recording
    let end: TimeInterval
    let text: String

    /// "00:01:23" style timestamp for the line's start.
    var timestamp: String {
        let total = Int(start)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

extension Array where Element == TranscriptLine {
    /// Render the transcript as plain text, one line per segment.
    var plainText: String {
        map { "[\($0.timestamp)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}
