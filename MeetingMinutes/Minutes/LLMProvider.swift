import Foundation

/// The LLM backends that can generate meeting minutes. Each carries the
/// metadata the UI and clients need; the request/response details live in the
/// per-provider `LLMClient` implementations.
enum LLMProvider: String, CaseIterable, Identifiable {
    case anthropic
    case openai
    case gemini
    case ollama

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openai: return "OpenAI (ChatGPT)"
        case .gemini: return "Google Gemini"
        case .ollama: return "Local (Ollama)"
        }
    }

    /// Cloud providers need an API key; Ollama runs locally and doesn't.
    var needsKey: Bool { self != .ollama }

    var keychainAccount: String { "\(rawValue)-api-key" }

    var defaultModel: String {
        switch self {
        case .anthropic: return "claude-sonnet-4-6"
        case .openai: return "gpt-4o"
        case .gemini: return "gemini-2.0-flash"
        case .ollama: return "llama3.1"
        }
    }

    var keyLabel: String {
        switch self {
        case .anthropic: return "Anthropic API Key"
        case .openai: return "OpenAI API Key"
        case .gemini: return "Google AI API Key"
        case .ollama: return ""
        }
    }

    var signupURL: URL? {
        switch self {
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .gemini: return URL(string: "https://aistudio.google.com/apikey")
        case .ollama: return URL(string: "https://ollama.com/download")
        }
    }

    var helpText: String {
        switch self {
        case .ollama:
            return "Runs entirely on your Mac — no API key, nothing leaves the device. Requires Ollama to be installed and running, with the model pulled (e.g. `ollama pull llama3.1`)."
        default:
            return "Used to generate meeting minutes. Stored securely in your macOS Keychain — never written to disk in plaintext. Your transcript is sent to this provider."
        }
    }
}

/// Persists the user's provider choice and per-provider model overrides.
enum MinutesSettings {
    private static let providerKey = "minutes.provider"

    static var provider: LLMProvider {
        get { LLMProvider(rawValue: UserDefaults.standard.string(forKey: providerKey) ?? "") ?? .anthropic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: providerKey) }
    }

    static func model(for provider: LLMProvider) -> String {
        let stored = UserDefaults.standard.string(forKey: "minutes.model.\(provider.rawValue)")
        if let stored, !stored.isEmpty { return stored }
        return provider.defaultModel
    }

    static func setModel(_ model: String, for provider: LLMProvider) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(trimmed, forKey: "minutes.model.\(provider.rawValue)")
    }
}
