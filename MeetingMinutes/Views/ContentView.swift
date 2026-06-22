import SwiftUI

/// Root layout: a sidebar listing past meetings (with search) plus a "New
/// Recording" entry, and a detail pane that shows either the recorder or the
/// selected meeting.
struct ContentView: View {
    @StateObject private var store = MeetingStore()
    @StateObject private var permissions = PermissionsManager()

    @State private var selection: Selection? = .record
    @State private var showSettings = false
    @State private var showPermissions = false

    private enum Selection: Hashable {
        case record
        case meeting(String)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .navigationTitle("Meeting Minutes")
        .toolbar {
            ToolbarItem {
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showPermissions) {
            PermissionsView(permissions: permissions) { showPermissions = false }
        }
        .onAppear {
            store.refresh()
            permissions.refresh()
            showPermissions = !permissions.allGranted
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
        .frame(minWidth: 820, minHeight: 560)
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section {
                Label("New Recording", systemImage: "record.circle")
                    .tag(Selection.record)
            }
            Section("Meetings") {
                if store.filtered.isEmpty {
                    Text(store.searchText.isEmpty ? "No recordings yet." : "No matches.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.filtered) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(Selection.meeting(meeting.id))
                            .contextMenu {
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
        .searchable(text: $store.searchText, placement: .sidebar, prompt: "Search transcripts")
        .frame(minWidth: 240)
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
            RecorderView { folder in
                store.refresh()
                selection = .meeting(folder.lastPathComponent)
            }
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
