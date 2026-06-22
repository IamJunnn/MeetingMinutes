import SwiftUI

/// Scrollable, color-coded transcript ("You" in accent, "Participant" in orange).
struct TranscriptListView: View {
    let lines: [TranscriptLine]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(lines) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(line.speaker)
                                .font(.caption.bold())
                                .foregroundStyle(line.speaker == "You" ? Color.accentColor : Color.orange)
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
