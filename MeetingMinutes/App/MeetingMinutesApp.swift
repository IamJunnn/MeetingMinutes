import SwiftUI

@main
struct MeetingMinutesApp: App {
    var body: some Scene {
        WindowGroup {
            RecordingView()
        }
        .windowResizability(.contentSize)
    }
}
