import Foundation
import SwiftWhisper

/// A stretch of one voice. Whoever worked out who spoke when, a diarizer or a cloud transcriber, hands these over;
/// this file does not care where they came from, which is what lets it live here rather than in one app.
struct SpeakerSegment {
    let speaker: String
    let start: TimeInterval
    let end: TimeInterval
    init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker; self.start = start; self.end = end
    }
}

/// Which whisper model to transcribe with, and how to get it.
///
/// Measured on an M-series Mac, transcribing one chunk, whisper alone: small 0.81 GB and 38s, medium 2.0 GB and 26s,
/// large-v2 3.67 GB and 131s. medium is the default because it is the point where English spoken inside a Korean
/// sentence comes back in English ("operation cost" rather than 아포레이션 코스트) without the app going past what a
/// meeting should ever cost in memory. large-v2 is the ceiling: SwiftWhisper is pinned at 1.2.0, whose whisper.cpp is
/// from August 2023 and takes the mel count as the compile time constant WHISPER_N_MEL = 80, so the 128 mel models
/// (large-v3, large-v3-turbo) are refused at load.
enum WhisperChoice {
    static let allowed = ["small", "medium", "large-v2"]
    static let defaultName = "medium"
    /// A host app can point this at a file holding one of `allowed`, to switch model without a rebuild.
    static var overrideFile: URL?
    /// What the linked whisper.cpp was compiled for. A model built for another mel count cannot be loaded.
    static let supportedMels: Int32 = 80

    static var name: String {
        guard let f = overrideFile,
              let raw = try? String(contentsOf: f, encoding: .utf8) else { return defaultName }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowed.contains(cleaned) ? cleaned : defaultName
    }
    static var fileName: String { "ggml-\(name).bin" }
    static var remote: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }
    static let fallbackFileName = "ggml-small.bin"

    /// Mel count from a ggml model header: magic, then eleven int32 fields, with n_mels the tenth.
    static func mels(of url: URL) -> Int32? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 44), d.count == 44 else { return nil }
        return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: Int32.self) }.littleEndian
    }
    /// Checked before use, so a mismatch is a clear note and a fallback rather than a failed load or a transcript of noise.
    static func usable(_ url: URL) -> Bool { mels(of: url) == supportedMels }

    static func directory() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingMinutes/Models", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The model to transcribe with, downloading it once if it is not here yet. A download failure is not fatal when
    /// the smaller model is already on disk: the meeting is still transcribed, and the caller is told which one ran.
    static func ensure(progress: @escaping (Double) -> Void) async throws -> (url: URL, note: String?) {
        let dir = try directory()
        let dest = dir.appendingPathComponent(fileName)
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            if usable(dest) { return (dest, nil) }
            NSLog("WhisperChoice: %@ needs a %d mel whisper build, this one is %d; removing it", fileName, mels(of: dest) ?? -1, supportedMels)
            try? fm.removeItem(at: dest)
        }
        do {
            try await download(remote, to: dest, progress: progress)
            guard usable(dest) else {
                try? fm.removeItem(at: dest)
                throw NSError(domain: "WhisperChoice", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(fileName) is built for a different mel count than this whisper build supports"])
            }
            NSLog("WhisperChoice: installed %@", fileName)
            return (dest, nil)
        } catch {
            let fallback = dir.appendingPathComponent(fallbackFileName)
            guard fm.fileExists(atPath: fallback.path) else { throw error }
            let why = error.localizedDescription
            NSLog("WhisperChoice: %@ not downloaded, falling back to %@: %@", fileName, fallbackFileName, why)
            return (fallback, "transcribed with the smaller model; \(fileName) could not be downloaded (\(why))")
        }
    }

    /// Downloads to a temporary file and moves it into place, so an interrupted download never leaves a half model
    /// behind that would look installed on the next run.
    private static func download(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let reporter = DownloadProgress(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: reporter, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (tmp, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
    }

    private final class DownloadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let onProgress: (Double) -> Void
        init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }
        func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
            task.progress.addObserver(self, forKeyPath: "fractionCompleted", options: [.new], context: nil)
        }
        override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            if let p = object as? Progress { onProgress(p.fractionCompleted) }
        }
    }
}

/// Primes the decoder with mixed-script text so English inside Korean speech comes back in Latin letters. whisper
/// treats this as the transcript that came just before, not as an instruction, so it is written as a sample of the
/// output we want rather than a request. Measured: with it, English words spelled out in Hangul fell from 23 to 6.
enum WhisperPrompt {
    static func mixedScript(extraTerms: [String] = []) -> String {
        var s = "한국어와 영어를 섞어서 이야기하는 회의입니다. 영어 단어와 고유명사는 영어 철자 그대로 적습니다. "
        s += "예: standard, district, projection, revenue, roadmap, meeting, school, design, refactoring."
        let terms = extraTerms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !terms.isEmpty { s += " " + terms.joined(separator: ", ") }
        return String(s.prefix(800))
    }
    /// The prompt's own sentences, loosely: on silence or noise whisper writes the prompt back out as if someone
    /// said it, sometimes with a syllable garbled ("고유명사늼"). Keep these in step with `mixedScript`.
    private static let echoes: [NSRegularExpression] = [
        #"한국어와\s*영어를\s*섞어서\s*이야기하는\s*회의입니다\.?"#,
        #"영어\s*단어와\s*고유명사.{0,2}\s*영어\s*철자\s*그대로\s*적.{0,2}니다\.?"#,
        #"(예[:.]\s*)?standard,\s*district,\s*projection[^.]*\.?"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    /// "예." and nothing else, three times or more: the "예:" that opens the prompt's example list, echoed.
    private static let bareYes = try! NSRegularExpression(pattern: #"^(예[.:]?\s*){3,}$"#)

    /// `text` with any echo of the prompt removed. Empty when the whole segment was the echo.
    static func removingEcho(_ text: String) -> String {
        var t = text
        for re in echoes { t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: "") }
        t = t.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if bareYes.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { return "" }
        return t
    }
    /// Terms from a file the owner can edit, one per line. Missing file means no extra terms.
    static func terms(in file: URL?) -> [String] {
        guard let file, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }
}

/// Transcribes with whisper, built for meetings that change language.
///
/// whisper decides the language ONCE, from the first thirty seconds it is given, and applies it to everything after.
/// A 74 minute meeting that opened in Korean and turned to English had its English half decoded as Korean, which
/// degenerated into a single invented phrase repeated 1,613 times and cost 53 of its 74 minutes. Two things fix that:
/// the audio goes in as chunks of about two minutes so the language is detected again and again, and where speaker
/// segments are known each person is transcribed on their own, because people are language-consistent even when the
/// room is not.
final class CodeSwitchTranscriber: Transcriber {
    private let modelURL: URL
    private let initialPrompt: String
    private var whisper: Whisper?
    /// initial_prompt is a borrowed C pointer that whisper does not copy, so the buffer has to outlive the context.
    private var promptBuffer: UnsafeMutablePointer<CChar>?
    /// Set by cancel(). Checked between chunks, so a stop never has to wait for the whole track.
    private var cancelled = false

    static let sampleRate = 16_000

    init(modelURL: URL, initialPrompt: String = WhisperPrompt.mixedScript()) {
        self.modelURL = modelURL
        self.initialPrompt = initialPrompt
    }

    deinit { free(promptBuffer) }

    /// Stop the run. whisper is told to stop inside the chunk it is decoding, and the loop gives up before the next
    /// one, so the longest a cancel can take is the rest of one two minute chunk.
    func cancel() {
        cancelled = true
        let running = whisper
        Task { try? await running?.cancel() }
    }

    /// Frees the model. Worth doing explicitly: it is gigabytes, and the caller usually has other work to finish.
    func unload() {
        whisper = nil
        free(promptBuffer)
        promptBuffer = nil
    }

    /// Performance cores only. Giving whisper the efficiency cores too makes the fast cores wait on the slow ones:
    /// measured 52s on 8 threads against 27s on 4, on a 6+2 machine.
    private static var performanceCoreCount: Int {
        var count: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &count, &size, nil, 0) == 0, count > 0 { return Int(count) }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    private func engine() -> Whisper {
        if let w = whisper { return w }
        let params = WhisperParams.default
        params.n_threads = Int32(Self.performanceCoreCount)
        // whisper writes "[Music]", "(구독과 좋아요)" and similar over silence. Suppressing the tokens that start
        // those stops them being generated at all, rather than filtering them out afterwards.
        params.suppress_non_speech_tokens = true
        let buffer = strdup(initialPrompt)
        promptBuffer = buffer
        params.initial_prompt = UnsafePointer(buffer)
        let w = Whisper(fromFileURL: modelURL, withParams: params)
        whisper = w
        return w
    }

    func decode(_ audioURL: URL) async throws -> [Float] {
        try await Task.detached(priority: .userInitiated) { try AudioDecoder.decodeTo16kMonoFloat(url: audioURL) }.value
    }

    func transcribe(audioURL: URL, speaker: String, diarize: Bool = false, progress: @escaping (Double) -> Void) async throws -> [TranscriptLine] {
        let frames = try await decode(audioURL)
        guard !frames.isEmpty else { return [] }
        return try await run(frames, progress: progress) { start, end, text in
            TranscriptLine(speaker: speaker, start: start, end: end, text: text)
        }
    }

    /// Transcribes one speaker's gathered audio, dating every line by when it was really said.
    func transcribe(stream: SpeakerStream, progress: @escaping (Double) -> Void) async throws -> [TranscriptLine] {
        guard !stream.samples.isEmpty else { return [] }
        return try await run(stream.samples, progress: progress) { start, end, text in
            let realStart = stream.realTime(start)
            return TranscriptLine(speaker: stream.speaker, start: realStart, end: realStart + max(0.2, end - start), text: text)
        }
    }

    /// Decodes audio in chunks of about two minutes, detecting the language for each one, and hands every surviving
    /// segment to `make` with times measured from the start of what it was given.
    private func run(_ frames: [Float], progress: @escaping (Double) -> Void,
                     _ make: (Double, Double, String) -> TranscriptLine?) async throws -> [TranscriptLine] {
        let whisper = engine()
        let ranges = Self.chunks(frames)
        var out: [TranscriptLine] = []
        for (i, r) in ranges.enumerated() {
            if cancelled { throw CancellationError() }
            whisper.params.language = .auto
            let base = Double(i) / Double(ranges.count), span = 1 / Double(ranges.count)
            whisper.delegate = ProgressDelegate { progress(base + $0 * span) }
            let segments = try await whisper.transcribe(audioFrames: Array(frames[r]))
            let offset = Double(r.lowerBound) / Double(Self.sampleRate)
            out += segments.compactMap { segment in
                let text = WhisperPrompt.removingEcho(segment.text).collapsingRepeatedTokens()
                guard !text.isEmpty, !Self.isNonSpeech(text) else { return nil }
                return make(Double(segment.startTime) / 1000 + offset, Double(segment.endTime) / 1000 + offset, text)
            }
        }
        progress(1)
        return out
    }

    /// One speaker's speech lifted out of a track and laid end to end, with an index that maps a position in the
    /// gathered audio back to when it was actually said.
    ///
    /// This is what makes a bilingual room work. whisper decides one language per decode, so a two minute chunk of a
    /// meeting where Michael speaks English while Chris answers in Korean has to pick one and ruins the other. People
    /// are language-consistent even when rooms are not, so each speaker is transcribed on their own and detected on
    /// their own. Silence between turns is dropped on the way, which is also why this is faster than decoding the
    /// whole track.
    struct SpeakerStream {
        let speaker: String
        var samples: [Float] = []
        /// (where a piece starts in `samples`, when it really happened, how long it is), all in seconds.
        var pieces: [(at: Double, real: Double, length: Double)] = []

        /// Real time for a position in the gathered audio. Positions inside the padding between two pieces belong to
        /// the piece that just ended, so a segment straddling a splice is dated by where it began.
        func realTime(_ t: Double) -> Double {
            guard let p = pieces.last(where: { $0.at <= t }) ?? pieces.first else { return t }
            return p.real + min(max(0, t - p.at), p.length)
        }
        var seconds: Double { Double(samples.count) / Double(CodeSwitchTranscriber.sampleRate) }
    }

    /// Gathers each speaker's segments into their own stream. Segments shorter than a moment are dropped: whisper
    /// cannot do anything with a quarter second of audio except invent something.
    static func streams(_ frames: [Float], segments: [SpeakerSegment], gap: Double = 0.3) -> [SpeakerStream] {
        let rate = Double(sampleRate)
        let padding = [Float](repeating: 0, count: Int(gap * rate))
        var bySpeaker: [String: SpeakerStream] = [:]
        for seg in merging(segments) {
            let length = seg.end - seg.start
            guard length >= 0.4 else { continue }
            let lo = max(0, Int(seg.start * rate)), hi = min(frames.count, Int(seg.end * rate))
            guard hi > lo else { continue }
            var stream = bySpeaker[seg.speaker] ?? SpeakerStream(speaker: seg.speaker)
            stream.pieces.append((at: stream.seconds, real: seg.start, length: Double(hi - lo) / rate))
            stream.samples.append(contentsOf: frames[lo..<hi])
            stream.samples.append(contentsOf: padding)
            bySpeaker[seg.speaker] = stream
        }
        // Longest first, so the owner hears progress on the person who talked most rather than on a one word answer.
        return bySpeaker.values.sorted { $0.seconds > $1.seconds }
    }

    /// Joins a speaker's turns that are close together into one span, keeping the audio in between.
    ///
    /// Cutting at every diarizer boundary was a real bug, not a theoretical one: a fast Korean exchange comes back
    /// from the diarizer as dozens of one and two second turns, and a stream built from those is a run of snippets
    /// with no context across them. whisper then reads short Korean utterances as stray English words, and a meeting
    /// that opened in Korean transcribed as "Okay. / Engineering. / California." A speaker talking in long turns was
    /// unaffected, which is exactly why only half the meeting looked wrong.
    static func merging(_ segments: [SpeakerSegment], within: Double = 2, minimum: Double = 1) -> [SpeakerSegment] {
        var out: [SpeakerSegment] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, last.speaker == seg.speaker, seg.start - last.end <= within {
                out[out.count - 1] = SpeakerSegment(speaker: last.speaker, start: last.start, end: max(last.end, seg.end))
            } else {
                out.append(seg)
            }
        }
        // A span too short to carry any context is left out; whisper invents something for a stray half second.
        return out.filter { $0.end - $0.start >= minimum }
    }

    /// Splits a track into chunks of about two minutes, cutting at the quietest moment near each boundary so a cut
    /// never lands in the middle of a word. Two minutes is long enough that language detection has plenty of speech
    /// to work from and short enough that one language change costs at most that much audio.
    static func chunks(_ frames: [Float], target: Int = 120, slack: Int = 20) -> [Range<Int>] {
        let target = target * sampleRate, slack = slack * sampleRate, win = sampleRate / 5   // 200 ms
        var out: [Range<Int>] = []
        var start = 0
        while start < frames.count {
            // A short tail is left on the previous chunk rather than made into a chunk of its own.
            if start + target + slack >= frames.count { out.append(start..<frames.count); break }
            var bestCut = start + target, quietest = Float.greatestFiniteMagnitude
            var i = max(start + target - slack, start + win)
            let limit = min(start + target + slack, frames.count - win)
            while i < limit {
                var energy: Float = 0
                for j in i..<(i + win) { energy += frames[j] * frames[j] }
                if energy < quietest { quietest = energy; bestCut = i + win / 2 }
                i += win
            }
            out.append(start..<bestCut)
            start = bestCut
        }
        return out
    }

    /// whisper.cpp annotates non-speech as text wholly wrapped in brackets or parentheses: [BLANK_AUDIO], (silence).
    private static func isNonSpeech(_ text: String) -> Bool {
        (text.hasPrefix("[") && text.hasSuffix("]") && !text.dropFirst().dropLast().contains("[")) ||
        (text.hasPrefix("(") && text.hasSuffix(")") && !text.dropFirst().dropLast().contains("("))
    }

    private final class ProgressDelegate: WhisperDelegate {
        let onProgress: (Double) -> Void
        init(onProgress: @escaping (Double) -> Void) { self.onProgress = onProgress }
        func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) { onProgress(progress) }
    }
}
