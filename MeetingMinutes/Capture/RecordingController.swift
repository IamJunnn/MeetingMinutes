import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import ScreenCaptureKit
import SwiftUI

/// Orchestrates a recording session: requests permissions, starts both capture
/// tracks, tracks elapsed time, and finalizes the files when stopped.
///
/// Each session lives in its own timestamped folder under Application Support:
///   …/MeetingMinutes/Recordings/<timestamp>/{mic.m4a, system.m4a}
///
/// There is exactly one recorder for the app (`shared`), owned above any view:
/// a recording must survive the user clicking around the library. When a view
/// owned it, navigating away deallocated the captures mid-recording, which
/// left the system-audio file without its index (unplayable, untranscribable).
@MainActor
final class RecordingController: ObservableObject {
    static let shared = RecordingController()

    enum State: Equatable {
        case idle
        case recording
        case finishing
        case error(String)
    }

    /// Why the last recording ended.
    enum StopReason: Equatable {
        case user
        /// Both tracks were quiet for `silenceTimeout` — the meeting was over
        /// and nobody pressed Stop.
        case silence
        /// The app was quit while recording; the files were finalized first.
        case quit
    }

    /// How long both tracks must be silent before a recording stops itself.
    static let silenceTimeout: TimeInterval = 10 * 60

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecordingFolder: URL?
    @Published private(set) var lastStopReason: StopReason?
    /// Folder of the in-progress recording, nil when idle. The library hides
    /// it until the files are finalized.
    @Published private(set) var activeFolder: URL?
    /// Seconds since either track last carried sound (0 while idle).
    @Published private(set) var silenceSeconds: TimeInterval = 0
    /// When true, only the mic keeps a recording alive. For a meeting in the
    /// room, whatever the Mac plays (a video, music) is not the meeting, and
    /// counting it kept a forgotten recording running for hours.
    var ignoresSystemAudio = false

    /// Listeners on the live tracks, for a transcript while the meeting runs:
    /// the buffer as captured and whether it carried sound, on the capture's
    /// own thread. Set them before `start`; they stay until the caller clears them.
    var onMicBuffer: ((AVAudioPCMBuffer, Bool) -> Void)? {
        get { mic.onBuffer }
        set { mic.onBuffer = newValue }
    }
    var onSystemBuffer: ((AVAudioPCMBuffer, Bool) -> Void)? {
        get { system.onBuffer }
        set { system.onBuffer = newValue }
    }
    /// Seconds the system track started after the mic track, once both have
    /// delivered a sample. Nil before that, or when a track is not running.
    var trackOffsetSeconds: Double? {
        guard let m = mic.firstSampleHostSeconds, let s = system.firstSampleHostSeconds else { return nil }
        return s - m
    }

    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private var startDate: Date?
    private var timer: Timer?
    private var currentFolder: URL?

    private init() {
        // Shutdown, restart, or logout: start finalizing now instead of waiting
        // for the quit that follows, which kills an app without a termination
        // hook mid-write.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.prepareForTermination() }
        }
    }

    var isRecording: Bool { state == .recording }
    var isBusy: Bool { state == .finishing }

    func toggle() {
        switch state {
        case .recording:
            Task { await stop() }
        case .idle, .error:
            Task { await start() }
        case .finishing:
            break
        }
    }

    func start() async {
        do {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else {
                state = .error("Microphone access denied. Enable it in System Settings → Privacy & Security → Microphone, then try again.")
                return
            }

            // ScreenCaptureKit needs Screen Recording permission for system audio. CGPreflightScreenCaptureAccess
            // reports "denied" on recent macOS until the app has actually touched ScreenCaptureKit, even when the
            // toggle is on, so probe the real thing: listing shareable content succeeds only with the grant.
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                _ = CGRequestScreenCaptureAccess()   // prompts on first run, or points at System Settings
                state = .error(CaptureError.screenRecordingDenied.localizedDescription)
                return
            }

            let folder = try makeSessionFolder()
            currentFolder = folder
            activeFolder = folder

            // Diagnostic toggles (env vars) to isolate which capture path ducks the
            // meeting audio: launch with MM_NO_SYSTEM=1 to run mic-only, or
            // MM_NO_MIC=1 to run system-audio-only. Absent → both run normally.
            let env = ProcessInfo.processInfo.environment
            let skipMic = env["MM_NO_MIC"] == "1"
            let skipSystem = env["MM_NO_SYSTEM"] == "1"

            if !skipMic {
                try mic.start(outputURL: folder.appendingPathComponent("mic.m4a"))
            }
            if !skipSystem {
                try await system.start(outputURL: folder.appendingPathComponent("system.m4a"))
            }

            startDate = Date()
            elapsed = 0
            silenceSeconds = 0
            startTimer()
            state = .recording
        } catch {
            await mic.stop()
            await system.stop()
            cleanUpFailedSession()
            state = .error(error.localizedDescription)
        }
    }

    /// If a session failed to start, it may have left behind an empty folder
    /// (e.g. a 0-byte mic file written before system capture was denied).
    /// Remove it so the library only ever shows real recordings.
    private func cleanUpFailedSession() {
        guard let folder = currentFolder else { return }
        try? FileManager.default.removeItem(at: folder)
        currentFolder = nil
        activeFolder = nil
    }

    func stop() async {
        await stop(reason: .user)
    }

    /// Finish a recording that's in flight so the app can exit without leaving
    /// half-written files: stops if recording, waits if already finishing.
    func prepareForTermination() async {
        switch state {
        case .recording:
            await stop(reason: .quit)
        case .finishing:
            while state == .finishing {
                try? await Task.sleep(for: .milliseconds(100))
            }
        case .idle, .error:
            break
        }
    }

    private func stop(reason: StopReason) async {
        guard state == .recording else { return }
        state = .finishing
        lastStopReason = reason
        stopTimer()
        await mic.stop()
        await system.stop()
        if let folder = currentFolder {
            // Record when each track's first sample actually arrived — system
            // capture starts later than the mic, and EchoCanceller uses this
            // gap to align the tracks.
            SessionTimes(micFirstSampleHostSeconds: mic.firstSampleHostSeconds,
                         systemFirstSampleHostSeconds: system.firstSampleHostSeconds).save(in: folder)
            // Warm the echo-cancelled mic now so playback and transcription
            // don't pay for the analysis on first use.
            Task.detached(priority: .utility) {
                _ = await EchoCanceller.shared.cleanedMicURL(in: folder)
            }
        }
        lastRecordingFolder = currentFolder
        activeFolder = nil
        silenceSeconds = 0
        state = .idle
    }

    // MARK: - Helpers

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                let now = Date()
                self.elapsed = now.timeIntervalSince(start)
                self.checkForSilence(at: now)
            }
        }
    }

    /// Auto-stop a forgotten recording: once neither the mic nor the system
    /// mix has carried sound for `silenceTimeout`, the meeting is over. A
    /// track that isn't running (diagnostic env vars) reports its start time,
    /// so only live tracks hold the recording open.
    private func checkForSilence(at now: Date) {
        guard state == .recording else { return }
        let lastSound = ignoresSystemAudio ? mic.lastActivityDate : max(mic.lastActivityDate, system.lastActivityDate)
        silenceSeconds = max(0, now.timeIntervalSince(lastSound))
        if silenceSeconds >= Self.silenceTimeout {
            Task { await stop(reason: .silence) }
        }
    }

    /// "HH:MM:SS" for the elapsed/silence displays.
    static func clockString(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func makeSessionFolder() throws -> URL {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MeetingMinutes/Recordings", isDirectory: true)
        let folder = base.appendingPathComponent(Self.folderFormatter.string(from: Date()), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static let folderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()
}
