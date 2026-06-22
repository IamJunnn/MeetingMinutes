import Foundation

/// Minimal client for the Anthropic Messages API (`POST /v1/messages`).
/// Swift has no official Anthropic SDK, so this calls the REST API directly.
struct ClaudeClient {
    enum ClientError: LocalizedError {
        case missingAPIKey
        case http(Int, String)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Anthropic API key set. Add one in Settings (the gear icon)."
            case .http(let code, let message):
                return "Claude API error (\(code)): \(message)"
            case .empty:
                return "Claude returned an empty response."
            }
        }
    }

    var apiKey: String
    var model = "claude-opus-4-8"

    func generate(system: String, user: String) async throws -> String {
        guard !apiKey.isEmpty else { throw ClientError.missingAPIKey }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 8192,
            "system": system,
            "messages": [["role": "user", "content": user]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ClientError.http(status, Self.errorMessage(from: data))
        }

        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard !text.isEmpty else { throw ClientError.empty }
        return text
    }

    private static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = object["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }

    private struct MessageResponse: Decodable {
        let content: [Block]
        struct Block: Decodable {
            let type: String
            let text: String?
        }
    }
}
