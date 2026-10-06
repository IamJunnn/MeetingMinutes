import AVFoundation
import Foundation

/// Minimal AVAudioPlayer wrapper for playing back a recording track in the
/// meeting detail view.
@MainActor
final class AudioPlayer: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var loadedURL: URL?

    private var player: AVAudioPlayer?
    private var timer: Timer?

    /// Load `url` for playback. `loadedURL` is set only when the file opened,
    /// so a failed load is retried next time instead of being mistaken for done.
    @discardableResult
    func load(_ url: URL) -> Bool {
        if url == loadedURL && player != nil { return true }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: url), player.duration > 0 else { return false }
        player.delegate = self
        player.prepareToPlay()
        self.player = player
        loadedURL = url
        duration = player.duration
        currentTime = 0
        return true
    }

    func togglePlay() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            stopTimer()
        } else {
            player.play()
            isPlaying = true
            startTimer()
        }
    }

    func seek(to time: TimeInterval) {
        player?.currentTime = time
        currentTime = time
    }

    func stop() {
        player?.stop()
        player = nil
        loadedURL = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        stopTimer()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

extension AudioPlayer: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.currentTime = 0
            self.stopTimer()
        }
    }
}
