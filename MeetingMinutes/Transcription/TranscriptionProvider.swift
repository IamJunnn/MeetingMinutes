import Foundation

/// The transcription backends. `local` runs whisper.cpp on-device (free,
/// private, key-less, but slow on long meetings and can't tell participants
/// apart). `deepgram` is a fast cloud service that *diarizes* — it separates
/// the participant track into per-person `Speaker 1, 2, 3…` labels.
enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case local
    case deepgram

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .local: return "On-device (Whisper)"
        case .deepgram: return "Deepgram (cloud · speaker labels)"
        }
    }

    /// Whether the system-audio track gets split into per-person speakers.
    var diarizes: Bool { self == .deepgram }

    var needsKey: Bool { self == .deepgram }

    var keychainAccount: String { "deepgram-api-key" }

    var keyLabel: String { "Deepgram API Key" }

    var signupURL: URL? {
        self == .deepgram ? URL(string: "https://console.deepgram.com/signup") : nil
    }

    var helpText: String {
        switch self {
        case .local:
            return "Runs entirely on your Mac — free, private, no key. Slower on long meetings, and labels audio only as “You” vs “Participant” (no per-person separation)."
        case .deepgram:
            return "Fast cloud transcription that separates each participant into Speaker 1, 2, 3… Also fixes slow transcription on long recordings. Your audio is sent to Deepgram. Requires an API key (free tier available)."
        }
    }
}

/// Persists the user's transcription-engine choice.
enum TranscriptionSettings {
    private static let providerKey = "transcription.provider"

    static var provider: TranscriptionProvider {
        get { TranscriptionProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .local }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }
}
