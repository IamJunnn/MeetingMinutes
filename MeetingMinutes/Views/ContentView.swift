import SwiftUI

/// Root layout: a sidebar listing past meetings (with search) plus a "New
/// Recording" entry, and a detail pane that shows either the recorder or the
/// selected meeting.
struct ContentView: View {
    @StateObject private var store = MeetingStore()
    @StateObject private var permissions = PermissionsManager()
    // App-wide recorder, deliberately not owned by RecorderView: the detail
    // pane is swapped out on every sidebar click, and a recording must outlive it.
    @ObservedObject private var recorder = RecordingController.shared

    @State private var selection: Selection? = .record
    @State private var showSettings = false
    @State private var showPermissions = false
    @State private var renameTarget: Meeting?
    @State private var renameDraft = ""
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    private enum Selection: Hashable {
        case record
        case meeting(String)
    }

    var body: some View {
        NavigationStack {
            HSplitView {
                sidebar
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 380, maxHeight: .infinity)
                detail
                    .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbar {
                ToolbarItem {
                    Button {
                        store.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh meetings")
                }
                ToolbarItem {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .help("Settings")
                }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .onChange(of: recorder.lastRecordingFolder) { _, folder in
            // Fires wherever the user is when the recording ends — including
            // an auto-stop while they're reading another meeting.
            guard let folder else { return }
            store.refresh()
            selection = .meeting(folder.lastPathComponent)
        }
        .alert(
            "Rename Meeting",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("Meeting name", text: $renameDraft)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let meeting = renameTarget { store.rename(meeting, to: renameDraft) }
            }
        } message: {
            Text("Leave empty to go back to the date.")
        }
        .sheet(isPresented: $showPermissions) {
            PermissionsView(permissions: permissions) {
                didCompleteOnboarding = true
                showPermissions = false
            }
        }
        .onAppear {
            store.refresh()
            permissions.refresh()
            // Only nag on a fresh install: not granted, never dismissed, and no
            // recordings yet (existing recordings prove permissions work).
            showPermissions = !permissions.allGranted && !didCompleteOnboarding && store.meetings.isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: .recordingsRepaired)) { _ in
            store.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
            store.refresh()
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search transcripts", text: $store.searchText)
                    .textFieldStyle(.plain)
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(7)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 10)
            .padding(.bottom, 4)

            List(selection: $selection) {
                Section {
                    recordRow
                        .tag(Selection.record)
                }
                Section("Meetings") {
                    if visibleMeetings.isEmpty {
                        Text(store.searchText.isEmpty ? "No recordings yet." : "No matches.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(visibleMeetings) { meeting in
                            MeetingRow(meeting: meeting)
                                .tag(Selection.meeting(meeting.id))
                                .contextMenu {
                                    Button("Rename…") {
                                        renameDraft = meeting.title
                                        renameTarget = meeting
                                    }
                                    Button("Reveal in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([meeting.folder])
                                    }
                                    Button("Delete", role: .destructive) {
                                        if selection == .meeting(meeting.id) { selection = .record }
                                        store.delete(meeting)
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
        }
        .frame(maxHeight: .infinity)
    }

    /// The in-progress recording's folder already exists on disk but its files
    /// aren't finalized — keep it out of the library until it's done.
    private var visibleMeetings: [Meeting] {
        store.filtered.filter { $0.folder != recorder.activeFolder }
    }

    /// "New Recording", turning into a live "Recording 00:12:34" indicator so a
    /// running recording is visible from anywhere in the app.
    @ViewBuilder
    private var recordRow: some View {
        if recorder.isRecording || recorder.isBusy {
            HStack {
                Label {
                    Text(recorder.isBusy ? "Finishing…" : "Recording")
                } icon: {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                }
                Spacer()
                Text(RecordingController.clockString(recorder.elapsed))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.red)
            }
        } else {
            Label("New Recording", systemImage: "record.circle")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .meeting(let id):
            if let meeting = store.meeting(id: id) {
                MeetingDetailView(meeting: meeting) { store.refresh() }
                    .id(meeting.id)
            } else {
                ContentUnavailableView("Meeting not found", systemImage: "questionmark.folder")
            }
        default:
            RecorderView(controller: recorder)
                .id("record")
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(meeting.title)
                .font(.body)
                .lineLimit(1)
            if meeting.customTitle != nil {
                Text(meeting.dateTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                badge("text.bubble", on: meeting.hasTranscript)
                badge("doc.text", on: meeting.hasMinutes)
            }
        }
        .padding(.vertical, 2)
    }

    private func badge(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.caption2)
            .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.35))
    }
}
