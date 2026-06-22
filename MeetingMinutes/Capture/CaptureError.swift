import Foundation

/// Errors that can surface while setting up or running audio capture.
enum CaptureError: LocalizedError {
    case noDisplay
    case noMicrophone
    case cannotAddInput
    case screenRecordingDenied

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display is available to capture system audio from."
        case .noMicrophone:
            return "No microphone input is available."
        case .cannotAddInput:
            return "Could not configure the audio file writer."
        case .screenRecordingDenied:
            return "Screen Recording permission is needed to capture the meeting's audio. Enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen the app."
        }
    }
}
