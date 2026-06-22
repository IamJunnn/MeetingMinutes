import AVFoundation
import CoreGraphics
import Foundation
import SwiftUI

/// Orchestrates a recording session: requests permissions, starts both capture
/// tracks, tracks elapsed time, and finalizes the files when stopped.
///
/// Each session lives in its own timestamped folder under Application Support:
///   …/MeetingMinutes/Recordings/<timestamp>/{mic.m4a, system.m4a}
@MainActor
final class RecordingController: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case finishing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var lastRecordingFolder: URL?

    private let mic = MicCapture()
    private let system = SystemAudioCapture()
    private var startDate: Date?
    private var timer: Timer?
    private var currentFolder: URL?

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

            // ScreenCaptureKit needs Screen Recording permission for system
            // audio. Check first so we can show clear guidance instead of a
            // cryptic "declined" error mid-capture.
            guard CGPreflightScreenCaptureAccess() else {
                _ = CGRequestScreenCaptureAccess()   // prompts on first run
                state = .error(CaptureError.screenRecordingDenied.localizedDescription)
                return
            }

            let folder = try makeSessionFolder()
            currentFolder = folder

            try mic.start(outputURL: folder.appendingPathComponent("mic.m4a"))
            try await system.start(outputURL: folder.appendingPathComponent("system.m4a"))

            startDate = Date()
            elapsed = 0
            startTimer()
            state = .recording
        } catch {
            mic.stop()
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
    }

    func stop() async {
        guard state == .recording else { return }
        state = .finishing
        stopTimer()
        mic.stop()
        await system.stop()
        lastRecordingFolder = currentFolder
        state = .idle
    }

    // MARK: - Helpers

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
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
