import Foundation

/// Cloud transcription via Deepgram's pre-recorded API. Uploads the m4a as-is
/// (no local decode), and — when `diarize` is on — returns per-person speaker
/// labels ("Speaker 1", "Speaker 2", …) so multiple participants on the single
/// mixed system-audio track can be told apart.
struct DeepgramTranscriber: Transcriber {
    var apiKey: String

    func transcribe(audioURL: URL, speaker: String, diarize: Bool, progress: @escaping (Double) -> Void) async throws -> [TranscriptLine] {
        progress(0.05)
        let audio = try Data(contentsOf: audioURL)

        var components = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        components.queryItems = [
            URLQueryItem(name: "model", value: "nova-2"),
            URLQueryItem(name: "smart_format", value: "true"),   // punctuation + casing
            URLQueryItem(name: "detect_language", value: "true"), // multilingual, matches local auto-detect
            URLQueryItem(name: "diarize", value: diarize ? "true" : "false")
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.upload(for: request, from: audio)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status, LLMHTTP.errorMessage(from: data)) }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        progress(1)

        guard let words = decoded.results.channels.first?.alternatives.first?.words, !words.isEmpty else {
            return []
        }
        return Self.group(words, speakerLabel: speaker, diarize: diarize)
    }

    /// Coalesce Deepgram's word stream into transcript lines, starting a new
    /// line whenever the speaker changes or a sentence ends.
    private static func group(_ words: [Response.Word], speakerLabel: String, diarize: Bool) -> [TranscriptLine] {
        var lines: [TranscriptLine] = []
        var current: [Response.Word] = []
        var currentSpeaker: Int?

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current
                .map { $0.punctuatedWord ?? $0.word }
                .joined(separator: " ")
                .collapsingRepeatedTokens()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            current = []
            guard !text.isEmpty else { return }
            let label = (diarize ? "\(speakerLabel) \((currentSpeaker ?? 0) + 1)" : speakerLabel)
            lines.append(TranscriptLine(speaker: label, start: first.start, end: last.end, text: text))
        }

        for word in words {
            let speaker = diarize ? (word.speaker ?? 0) : 0
            if let cs = currentSpeaker, speaker != cs, !current.isEmpty { flush() }
            currentSpeaker = speaker
            current.append(word)
            // Break the line at sentence boundaries to keep segments readable.
            if let terminator = (word.punctuatedWord ?? word.word).last, ".?!".contains(terminator) {
                flush()
            }
        }
        flush()
        return lines
    }

    // MARK: - Response

    private struct Response: Decodable {
        let results: Results
        struct Results: Decodable { let channels: [Channel] }
        struct Channel: Decodable { let alternatives: [Alternative] }
        struct Alternative: Decodable { let words: [Word] }
        struct Word: Decodable {
            let word: String
            let start: Double
            let end: Double
            let speaker: Int?
            let punctuatedWord: String?

            enum CodingKeys: String, CodingKey {
                case word, start, end, speaker
                case punctuatedWord = "punctuated_word"
            }
        }
    }
}
