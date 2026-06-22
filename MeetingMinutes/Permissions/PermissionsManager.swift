import AVFoundation
import CoreGraphics
import AppKit

/// Tracks and requests the two permissions Meeting Minutes needs: Microphone
/// and Screen Recording (the latter is required by ScreenCaptureKit to capture
/// system audio).
@MainActor
final class PermissionsManager: ObservableObject {
    enum Status {
        case granted
        case notGranted   // denied or not-yet-decided — both need user action
    }

    @Published private(set) var microphone: Status = .notGranted
    @Published private(set) var screenRecording: Status = .notGranted

    var allGranted: Bool { microphone == .granted && screenRecording == .granted }

    init() { refresh() }

    /// Re-reads the current authorization state. Call when the app regains focus
    /// (e.g. after the user returns from System Settings).
    func refresh() {
        microphone = (AVCaptureDevice.authorizationStatus(for: .audio) == .authorized) ? .granted : .notGranted
        // Preflight can't distinguish "denied" from "not yet asked" — either way
        // it isn't granted, which is all the UI needs to know.
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .notGranted
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
    }

    /// Triggers the system Screen Recording prompt the first time; once the user
    /// has decided, this is a no-op and they must use System Settings instead.
    func requestScreenRecording() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    func openScreenRecordingSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunches the app — required for macOS to apply a newly granted Screen
    /// Recording permission (it's only read at launch).
    func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}
