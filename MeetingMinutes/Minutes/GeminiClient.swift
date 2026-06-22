import Foundation

/// Google Gemini via the Generative Language API (`:generateContent`).
struct GeminiClient: LLMClient {
    var apiKey: String
    var model: String

    func generate(system: String, user: String) async throws -> String {
        let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"
        var components = URLComponents(string: endpoint)!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": user]]]]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status, LLMHTTP.errorMessage(from: data)) }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.candidates.first?.content.parts.compactMap(\.text).joined() ?? ""
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }

    private struct Response: Decodable {
        let candidates: [Candidate]
        struct Candidate: Decodable { let content: Content }
        struct Content: Decodable { let parts: [Part] }
        struct Part: Decodable { let text: String? }
    }
}
