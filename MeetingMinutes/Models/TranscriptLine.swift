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

extension String {
    /// Collapse runaway ASR/echo repetition — any run of the same
    /// whitespace-separated token repeated 3+ times (e.g. Whisper looping
    /// "그 그 그 그 …" on filler or echo) is reduced to a single token. Genuine
    /// short repeats like "no no" or "very very" are left untouched.
    func collapsingRepeatedTokens() -> String {
        let tokens = split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count > 2 else { return self }
        var out: [Substring] = []
        var i = 0
        while i < tokens.count {
            var j = i + 1
            while j < tokens.count, tokens[j] == tokens[i] { j += 1 }
            let run = j - i
            // Keep one for a collapsed run (3+), otherwise keep all.
            for _ in 0..<(run >= 3 ? 1 : run) { out.append(tokens[i]) }
            i = j
        }
        return out.joined(separator: " ")
    }
}

extension Array where Element == TranscriptLine {
    /// Render the transcript as plain text, one line per segment.
    var plainText: String {
        map { "[\($0.timestamp)] \($0.speaker): \($0.text)" }.joined(separator: "\n")
    }
}
