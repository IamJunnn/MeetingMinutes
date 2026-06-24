import SwiftUI

/// Scrollable, color-coded transcript. "You" is the accent color; each
/// participant (or numbered speaker) gets its own stable color. `names` maps a
/// canonical speaker label ("Speaker 1") to a display name ("Sarah").
struct TranscriptListView: View {
    let lines: [TranscriptLine]
    var names: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(names[line.speaker] ?? line.speaker)
                                .font(.caption.bold())
                                .foregroundStyle(SpeakerColor.color(for: line.speaker))
                            Text(line.timestamp)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(line.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
    }
}
