import Foundation

/// Builds an `LLMClient` for the user's active minutes provider. Shared by
/// `MinutesService` (to write minutes) and `SpeakerNamer` (to name speakers),
/// so the provider-selection logic lives in exactly one place.
enum LLMClientFactory {
    /// - Throws: `LLMError.missingKey` if the active provider needs a key and none is set.
    static func makeActive() throws -> LLMClient {
        let provider = MinutesSettings.provider
        let model = MinutesSettings.model(for: provider)

        switch provider {
        case .anthropic, .openai, .gemini:
            guard let key = KeychainStore.load(account: provider.keychainAccount), !key.isEmpty else {
                throw LLMError.missingKey(provider: provider.displayName)
            }
            switch provider {
            case .anthropic: return AnthropicClient(apiKey: key, model: model)
            case .openai: return OpenAIClient(apiKey: key, model: model)
            case .gemini: return GeminiClient(apiKey: key, model: model)
            case .ollama: break   // unreachable
            }
        case .ollama:
            return OllamaClient(model: model)
        }
        // Unreachable, but the compiler can't see that.
        throw LLMError.missingKey(provider: provider.displayName)
    }
}
