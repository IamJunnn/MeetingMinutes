import AVFoundation

/// Produces a single mixed audio file for a meeting from its separate mic and
/// system tracks, so playback is "the whole meeting" rather than two tracks.
/// The mixed file is cached as `meeting.m4a` next to the originals.
enum AudioMixer {
    static func mixedURL(for meeting: Meeting) async -> URL? {
        let fm = FileManager.default
        let mixed = meeting.folder.appendingPathComponent("meeting.m4a")

        // Return the cached mix only if it's actually a valid, playable file. A
        // previous failed export can leave a corrupt stub on disk; trusting
        // `fileExists` alone would cache that failure forever, so verify it
        // opens with a real duration and otherwise drop it and rebuild.
        if fm.fileExists(atPath: mixed.path) {
            if await isPlayable(mixed) { return mixed }
            try? fm.removeItem(at: mixed)
        }

        let mic = meeting.micURL
        let system = meeting.systemURL
        let haveMic = fm.fileExists(atPath: mic.path)
        let haveSystem = fm.fileExists(atPath: system.path)

        // Nothing to mix — just return whichever single track exists.
        if haveMic && !haveSystem { return mic }
        if haveSystem && !haveMic { return system }
        guard haveMic && haveSystem else { return nil }

        let composition = AVMutableComposition()
        var inputParameters: [AVMutableAudioMixInputParameters] = []
        for url in [mic, system] {
            let asset = AVURLAsset(url: url)
            guard let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first,
                  let duration = try? await asset.load(.duration),
                  let dest = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            // Both tracks start at zero, so the export sums them into one mix.
            try? dest.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
            // Explicit per-track volume gives the exporter a defined down-mix.
            // Without it, summing a mono and a stereo track (no channel layout)
            // can make the AppleM4A export fail outright.
            let params = AVMutableAudioMixInputParameters(track: dest)
            params.setVolume(1, at: .zero)
            inputParameters.append(params)
        }

        // A leftover partial file at the output URL makes the export fail, so
        // always start from a clean slate.
        try? fm.removeItem(at: mixed)

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return mic
        }
        export.outputURL = mixed
        export.outputFileType = .m4a
        let audioMix = AVMutableAudioMix()
        audioMix.inputParameters = inputParameters
        export.audioMix = audioMix

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { continuation.resume() }
        }

        // Only trust a fully completed export that produced a playable file;
        // otherwise clean up the partial output and fall back to the mic track.
        if export.status == .completed, await isPlayable(mixed) {
            return mixed
        }
        try? fm.removeItem(at: mixed)
        return mic
    }

    /// Whether an audio file opens and reports a real (non-zero) duration —
    /// used to reject corrupt or truncated mixes instead of caching them.
    private static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return false }
        return duration.seconds > 0.5
    }
}
