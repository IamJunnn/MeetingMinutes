import Foundation

/// A backend that turns a system prompt + user content into text. One
/// implementation per provider; all share this interface so `MinutesService`
/// doesn't care which is active.
protocol LLMClient {
    func generate(system: String, user: String) async throws -> String
}

enum LLMError: LocalizedError {
    case missingKey(provider: String)
    case http(Int, String)
    case connection(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .missingKey(let provider):
            return "No \(provider) API key set. Add one in Settings (the gear icon)."
        case .http(let code, let message):
            return "API error (\(code)): \(message)"
        case .connection(let message):
            return message
        case .empty:
            return "The model returned an empty response."
        }
    }
}

/// Shared helpers for the REST clients.
enum LLMHTTP {
    static func errorMessage(from data: Data) -> String {
        // OpenAI/Gemini: {"error":{"message":...}}; Anthropic: {"error":{"message":...}}
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
