import Foundation

/// Puts real names to the anonymous "Speaker 1/2/3…" labels that diarization
/// produces, by asking the active LLM to read the transcript and pick out names
/// from introductions and direct address ("I'm Sarah", "Thanks, Mike"). Only
/// confident guesses are returned; everything else stays a numbered speaker and
/// the user can fix it by hand.
enum SpeakerNamer {
    /// - Returns: a map of canonical label → inferred name, e.g. `["Speaker 1": "Sarah"]`.
    ///            Empty when nothing could be identified.
    static func inferNames(from lines: [TranscriptLine], labels: Set<String>, using client: LLMClient) async throws -> [String: String] {
        guard !labels.isEmpty else { return [:] }
        let reply = try await client.generate(system: systemPrompt, user: lines.plainText)
        return parse(reply, allowed: labels)
    }

    /// Pull the first JSON object out of the reply and keep only valid,
    /// confident name assignments for known speaker labels.
    private static func parse(_ reply: String, allowed: Set<String>) -> [String: String] {
        guard let start = reply.firstIndex(of: "{"),
              let end = reply.lastIndex(of: "}"),
              start < end else { return [:] }
        let json = String(reply[start...end])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }

        var result: [String: String] = [:]
        for (label, name) in raw {
            let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard allowed.contains(label), !cleaned.isEmpty, cleaned != label else { continue }
            result[label] = cleaned
        }
        return result
    }

    private static let systemPrompt = """
    You identify speakers in a meeting transcript. Lines are labeled "You" (the person running the app) and anonymous "Speaker 1", "Speaker 2", … for the other participants.

    Infer each anonymous speaker's name ONLY when the transcript gives clear evidence — someone introduces themselves ("I'm Sarah", "This is Mike speaking"), or is directly addressed in a way that unambiguously maps to a speaker ("Thanks, Sarah", "Mike, what do you think?").

    Respond with ONLY a JSON object mapping the speaker label to the name, including ONLY speakers you are confident about. Omit anyone you cannot confidently name. Never rename "You". Example: {"Speaker 1": "Sarah", "Speaker 3": "Mike"}. If you can't identify anyone, respond with {}.
    """
}
