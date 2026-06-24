import SwiftUI

/// Stable color for a speaker label so each person reads consistently across
/// the transcript. "You" is always the accent color; numbered speakers cycle a
/// fixed palette keyed on their number. Coloring is keyed on the *canonical*
/// label (e.g. "Speaker 2"), so renaming a speaker keeps their color.
enum SpeakerColor {
    private static let palette: [Color] = [.orange, .purple, .teal, .pink, .green, .indigo, .brown, .red]

    static func color(for canonicalLabel: String) -> Color {
        if canonicalLabel == "You" { return .accentColor }
        if canonicalLabel == "Participant" { return .orange }
        if let number = Int(canonicalLabel.split(separator: " ").last ?? "") {
            return palette[(max(1, number) - 1) % palette.count]
        }
        return palette[abs(canonicalLabel.hashValue) % palette.count]
    }
}
