import Foundation

/// Turns a transcript into AI-generated meeting minutes via the Claude API,
/// and writes the result as `minutes.md` next to the recording.
@MainActor
final class MinutesService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case generating
        case completed
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var markdown: String = ""

    var isGenerating: Bool { phase == .generating }

    func generate(from lines: [TranscriptLine], folder: URL) async {
        let client: LLMClient
        do {
            client = try LLMClientFactory.makeActive()
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        phase = .generating
        markdown = ""
        do {
            let result = try await client.generate(system: Self.systemPrompt, user: lines.plainText)
            markdown = result
            try? result.write(to: folder.appendingPathComponent("minutes.md"), atomically: true, encoding: .utf8)
            phase = .completed
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private static let systemPrompt = """
    You are an expert meeting-minutes assistant. You receive a meeting transcript whose lines are labeled by speaker, each with a timestamp. "You" is the person running the app. Other speakers are either named (e.g. "Sarah") or, when their name is unknown, labeled "Speaker 1", "Speaker 2", … — attribute decisions and action items to whichever label/name spoke them.

    Produce concise, well-structured meeting minutes in Markdown with exactly these three sections:

    ## Summary
    A short paragraph (2–4 sentences) capturing the meeting's purpose and outcome.

    ## Key Decisions
    A bulleted list of concrete decisions that were made. If none, write "None recorded."

    ## Action Items
    A bulleted list of follow-up tasks. Format each as: **Owner** — task (include a due date only if one was mentioned). Use "Unassigned" when the owner is unclear.

    Base everything strictly on the transcript — do not invent details. Write in the meeting's primary language.
    """
}
