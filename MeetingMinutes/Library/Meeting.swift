import Foundation

/// One past recording session, backed by its folder on disk.
struct Meeting: Identifiable, Hashable {
    let id: String          // folder name, e.g. "2026-06-22_07-50-49"
    let folder: URL
    let date: Date
    let hasMic: Bool
    let hasSystem: Bool
    let hasTranscript: Bool
    let hasMinutes: Bool

    var micURL: URL { folder.appendingPathComponent("mic.m4a") }
    var systemURL: URL { folder.appendingPathComponent("system.m4a") }
    var transcriptJSONURL: URL { folder.appendingPathComponent("transcript.json") }
    var transcriptTextURL: URL { folder.appendingPathComponent("transcript.txt") }
    var minutesURL: URL { folder.appendingPathComponent("minutes.md") }

    /// Human-readable title derived from the recording's date.
    var title: String { Self.displayFormatter.string(from: date) }

    func loadTranscript() -> [TranscriptLine] {
        guard let data = try? Data(contentsOf: transcriptJSONURL),
              let lines = try? JSONDecoder().decode([TranscriptLine].self, from: data) else {
            return []
        }
        return lines
    }

    func loadMinutes() -> String {
        (try? String(contentsOf: minutesURL, encoding: .utf8)) ?? ""
    }

    static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
