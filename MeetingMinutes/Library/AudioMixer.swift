import AVFoundation

/// Produces a single mixed audio file for a meeting from its separate mic and
/// system tracks, so playback is "the whole meeting" rather than two tracks.
/// The mixed file is cached as `meeting.m4a` next to the originals.
enum AudioMixer {
    static func mixedURL(for meeting: Meeting) async -> URL? {
        let fm = FileManager.default
        let mixed = meeting.folder.appendingPathComponent("meeting.m4a")
        if fm.fileExists(atPath: mixed.path) { return mixed }

        let mic = meeting.micURL
        let system = meeting.systemURL
        let haveMic = fm.fileExists(atPath: mic.path)
        let haveSystem = fm.fileExists(atPath: system.path)

        // Nothing to mix — just return whichever single track exists.
        if haveMic && !haveSystem { return mic }
        if haveSystem && !haveMic { return system }
        guard haveMic && haveSystem else { return nil }

        let composition = AVMutableComposition()
        for url in [mic, system] {
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  let dest = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            // Both tracks start at zero, so the export sums them into one mix.
            try? dest.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return mic
        }
        export.outputURL = mixed
        export.outputFileType = .m4a

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }

        return fm.fileExists(atPath: mixed.path) ? mixed : mic
    }
}
