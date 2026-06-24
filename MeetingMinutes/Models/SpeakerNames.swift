import Foundation

/// Display names for diarized speakers, persisted as `speakers.json` next to
/// the recording. Kept separate from `transcript.json` so renaming a speaker
/// is a cheap overlay write and never rewrites (or risks corrupting) the
/// transcript. Keys are the canonical labels from transcription ("Speaker 1");
/// values are the human name to show ("Sarah").
enum SpeakerNamesStore {
    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent("speakers.json")
    }

    static func load(in folder: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: url(in: folder)),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return map
    }

    static func save(_ names: [String: String], in folder: URL) {
        let target = url(in: folder)
        if names.isEmpty {
            try? FileManager.default.removeItem(at: target)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(names) else { return }
        try? data.write(to: target)
    }
}
