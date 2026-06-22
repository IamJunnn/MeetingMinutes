import SwiftUI

/// First-run / when-needed onboarding that walks the user through granting the
/// Microphone and Screen Recording permissions, and explains the relaunch
/// requirement that trips everyone up.
struct PermissionsView: View {
    @ObservedObject var permissions: PermissionsManager
    var onContinue: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Meeting Minutes")
                    .font(.title2.bold())
                Text("To record meetings, the app needs two macOS permissions. Your audio is processed and stored only on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                title: "Microphone",
                detail: "Records your voice.",
                status: permissions.microphone,
                grant: { Task { await permissions.requestMicrophone() } },
                openSettings: permissions.openMicrophoneSettings
            )

            permissionRow(
                title: "Screen & System Audio Recording",
                detail: "Required by macOS to capture the meeting's audio (the other participants). The app does not record your screen.",
                status: permissions.screenRecording,
                grant: permissions.requestScreenRecording,
                openSettings: permissions.openScreenRecordingSettings
            )

            if permissions.screenRecording != .granted {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Already enabled it in System Settings? macOS only applies Screen Recording after a restart — relaunch to finish.",
                          systemImage: "arrow.clockwise.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Quit & Reopen") { permissions.relaunch() }
                        .buttonStyle(.borderedProminent)
                }
            }

            Label("Recording meetings may require everyone's consent depending on where you are. Make sure you have permission.",
                  systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Re-check") { permissions.refresh() }
                Spacer()
                Button(permissions.allGranted ? "Get Started" : "Continue Anyway", action: onContinue)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 480)
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        detail: String,
        status: PermissionsManager.Status,
        grant: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: status == .granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(status == .granted ? .green : .secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if status != .granted {
                    HStack(spacing: 8) {
                        Button("Grant", action: grant)
                        Button("Open System Settings", action: openSettings)
                            .buttonStyle(.link)
                    }
                    .padding(.top, 2)
                }
            }
            Spacer()
        }
    }
}

#Preview {
    PermissionsView(permissions: PermissionsManager(), onContinue: {})
}
