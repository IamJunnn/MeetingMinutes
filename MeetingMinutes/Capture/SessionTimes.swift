import Foundation

/// Host-clock timestamps of each track's first captured sample, written to
/// `session.json` when a recording stops.
///
/// The two capture pipelines start at different real-world moments — system
/// audio needs a ScreenCaptureKit content fetch and stream spin-up, so it
/// typically begins a few hundred ms after the mic. This gap seeds the
/// track-alignment search in `EchoCanceller` so playback and transcription can
/// place both tracks on one timeline.
struct SessionTimes: Codable {
    var micFirstSampleHostSeconds: Double?
    var systemFirstSampleHostSeconds: Double?

    /// Seconds the system track starts after the mic track, when both are known.
    var hintOffsetSeconds: Double? {
        guard let mic = micFirstSampleHostSeconds,
              let system = systemFirstSampleHostSeconds else { return nil }
        return system - mic
    }

    static func url(in folder: URL) -> URL {
        folder.appendingPathComponent("session.json")
    }

    static func load(in folder: URL) -> SessionTimes? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        return try? JSONDecoder().decode(SessionTimes.self, from: data)
    }

    func save(in folder: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.url(in: folder), options: .atomic)
    }
}
