import SwiftUI

@main
struct MeetingMinutesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 980, height: 680)
    }
}

/// Keeps a live recording from being lost on quit: Cmd-Q (or logout/shutdown)
/// waits for the capture files to be finalized before the process exits.
/// Without this the system-audio file is left without its index and can't be
/// played or transcribed.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Recordings cut off by a shutdown or crash are rebuilt before anyone opens them.
        RecordingRepair.repairAllInBackground()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let recorder = RecordingController.shared
        guard recorder.isRecording || recorder.isBusy else { return .terminateNow }
        Task { @MainActor in
            await recorder.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
