import Foundation

/// Scans the Recordings directory and exposes the past meetings, with text
/// search across titles and transcripts. Filesystem-backed — no database — so
/// it works with whatever is already on disk.
@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [Meeting] = []
    @Published var searchText: String = ""

    private var transcriptCache: [String: String] = [:]

    static func recordingsDirectory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingMinutes/Recordings", isDirectory: true)
    }

    var filtered: [Meeting] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return meetings }
        return meetings.filter { meeting in
            meeting.title.lowercased().contains(query) || transcriptText(for: meeting).contains(query)
        }
    }

    func meeting(id: String) -> Meeting? {
        meetings.first { $0.id == id }
    }

    func refresh() {
        transcriptCache.removeAll()
        let fm = FileManager.default
        guard let base = try? Self.recordingsDirectory(),
              let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey]) else {
            meetings = []
            return
        }

        meetings = entries.compactMap { url -> Meeting? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let name = url.lastPathComponent
            let creation = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            let date = Meeting.folderFormatter.date(from: name) ?? creation ?? .distantPast
            return Meeting(
                id: name,
                folder: url,
                date: date,
                hasMic: fm.fileExists(atPath: url.appendingPathComponent("mic.m4a").path),
                hasSystem: fm.fileExists(atPath: url.appendingPathComponent("system.m4a").path),
                hasTranscript: fm.fileExists(atPath: url.appendingPathComponent("transcript.json").path),
                hasMinutes: fm.fileExists(atPath: url.appendingPathComponent("minutes.md").path),
                customTitle: Meeting.loadCustomTitle(in: url)
            )
        }
        .sorted { $0.date > $1.date }
    }

    /// Persist a user-chosen title to `title.txt` in the meeting folder. A
    /// blank title (or the date default) removes the file, reverting to the
    /// date-derived name. The folder itself is never renamed — it's the id.
    func rename(_ meeting: Meeting, to newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == meeting.dateTitle {
            try? FileManager.default.removeItem(at: meeting.titleURL)
        } else {
            try? trimmed.write(to: meeting.titleURL, atomically: true, encoding: .utf8)
        }
        refresh()
    }

    func delete(_ meeting: Meeting) {
        try? FileManager.default.removeItem(at: meeting.folder)
        refresh()
    }

    private func transcriptText(for meeting: Meeting) -> String {
        if let cached = transcriptCache[meeting.id] { return cached }
        let text = ((try? String(contentsOf: meeting.transcriptTextURL, encoding: .utf8)) ?? "").lowercased()
        transcriptCache[meeting.id] = text
        return text
    }
}
