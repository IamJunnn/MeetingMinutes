import Foundation

/// Everything that has to happen to a raw whisper transcript before a person, or a model writing minutes, should be
/// allowed to read it. Written against real failures on real meetings, with the numbers that justify each one.
enum TranscriptCleanup {
    /// The transcript as it should be read: whisper's silence loops removed, then the surviving fragments joined
    /// into paragraphs. Idempotent, so it also runs over transcripts saved before any of this existed.
    static func cleaned(_ lines: [TranscriptLine]) -> [TranscriptLine] { paragraphs(withoutEcho(dropLoops(lines))) }

    /// Drops "You" lines that are really someone else's voice coming out of the speakers and back into the mic. The
    /// echo canceller works on the audio; this is the backstop on the text, for what survives it. Without it the other
    /// side's words are attributed to the owner, and the minutes then credit them with things they never said.
    /// Measured on a meeting flagged bleedDetected: 9 of 92 "You" lines were the other side.
    static func withoutEcho(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        let others = lines.filter { $0.speaker != "You" }
        guard !others.isEmpty else { return lines }
        return lines.filter { line in
            guard line.speaker == "You" else { return true }
            return !others.contains { overlapping(line, $0) && sharesMostWords(line.text, $0.text) }
        }
    }

    /// Time spans that touch, with a second of slack for the delay between a speaker playing and the mic hearing it.
    private static func overlapping(_ a: TranscriptLine, _ b: TranscriptLine, slack: TimeInterval = 1) -> Bool {
        a.start < b.end + slack && b.start < a.end + slack
    }

    /// True when most of the shorter line's words appear in the longer one. Containment rather than a symmetric
    /// measure on purpose: an echoed line usually carries extra filler around the words it copied.
    private static func sharesMostWords(_ x: String, _ y: String, threshold: Double = 0.6) -> Bool {
        let sx = Set(x.split(separator: " ")), sy = Set(y.split(separator: " "))
        let shorter = sx.count <= sy.count ? sx : sy, longer = sx.count <= sy.count ? sy : sx
        guard !shorter.isEmpty else { return false }
        return Double(shorter.intersection(longer).count) / Double(shorter.count) >= threshold
    }

    /// whisper.cpp loops on silence: it emits one invented phrase over and over, and it attributes the copies to
    /// whichever speaker the diarizer guessed, so they do not even arrive in a run. Real speech repeats too, so a
    /// count alone cannot tell them apart. Across the recordings on this Mac the most repeated genuine fragment was
    /// 17% of its transcript ("Yeah.", "네.", "Right?") while a loop was 75%, so a fragment has to be both frequent
    /// and dominant before it goes.
    static func dropLoops(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        guard lines.count >= 40 else { return lines }
        var counts: [String: Int] = [:]
        for l in lines { counts[bare(l.text), default: 0] += 1 }
        let loops = Set(counts.filter { $0.value >= 20 && Double($0.value) / Double(lines.count) > 0.35 }.keys)
        guard !loops.isEmpty else { return lines }
        let removed = loops.reduce(0) { $0 + (counts[$1] ?? 0) }
        NSLog("MeetingTranscription: dropped %d of %d fragments as looped whisper output", removed, lines.count)
        return lines.filter { !loops.contains(bare($0.text)) }
    }

    /// Whisper emits a segment per breath, so a raw transcript is a column of two second fragments with a speaker name
    /// and a timestamp over each one. Join consecutive segments from the same speaker into paragraphs: same speaker,
    /// a short enough silence between them, and capped so one monologue does not become a wall of text. Idempotent,
    /// so it can also run over a transcript that was saved before this existed.
    static func paragraphs(_ lines: [TranscriptLine]) -> [TranscriptLine] {
        let maxGap: TimeInterval = 2, maxSpan: TimeInterval = 40, maxChars = 300
        var out: [TranscriptLine] = []
        var previous = ""   // the last fragment on its own, to spot whisper emitting the same one twice
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            if let last = out.last, last.speaker == line.speaker,
               line.start - last.end <= maxGap, line.end - last.start <= maxSpan,
               last.text.count + text.count <= maxChars {
                // whisper sometimes emits the same fragment twice in a row. Drop the second one, but only on an exact
                // repeat of the fragment before it, or on a long enough tail: with fragments this short, a loose
                // suffix test throws away ordinary speech that happens to end the same way.
                if bare(text) == bare(previous) || (bare(text).count >= 12 && bare(last.text).hasSuffix(bare(text))) {
                    out[out.count - 1] = TranscriptLine(speaker: last.speaker, start: last.start, end: max(last.end, line.end), text: last.text)
                } else {
                    out[out.count - 1] = TranscriptLine(speaker: last.speaker, start: last.start, end: max(last.end, line.end), text: joined(last.text, text))
                }
            } else {
                out.append(TranscriptLine(speaker: line.speaker, start: line.start, end: line.end, text: text))
            }
            previous = text
        }
        return out
    }

    /// Text with the whitespace taken out, for comparing two segments that say the same thing but space it differently.
    private static func bare(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).joined()
    }

    /// Korean and English put a space between words, Chinese and Japanese do not, and nothing goes in front of
    /// closing punctuation. Hangul counts as spaced, which is why it is not in `tightScript`.
    private static func joined(_ a: String, _ b: String) -> String {
        guard let last = a.unicodeScalars.last, let first = b.unicodeScalars.first else { return a + b }
        let glue = ",.!?;:)]}\u{2026}\u{3001}\u{3002}\u{FF0C}\u{FF01}\u{FF1F}"
        if glue.unicodeScalars.contains(first) { return a + b }
        if tightScript(last) && tightScript(first) { return a + b }
        return a + " " + b
    }

    /// True for scripts written without spaces between words: kana and CJK ideographs.
    private static func tightScript(_ s: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0x4E00...0x9FFF).contains(s.value)
    }

}
