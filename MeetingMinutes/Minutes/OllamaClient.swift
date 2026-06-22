import Foundation

/// A local model served by Ollama (`POST /api/chat`). No API key — runs
/// entirely on the user's Mac.
struct OllamaClient: LLMClient {
    var model: String
    var host = "http://localhost:11434"

    func generate(system: String, user: String) async throws -> String {
        var request = URLRequest(url: URL(string: "\(host)/api/chat")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw LLMError.connection("Couldn't reach Ollama at \(host). Make sure Ollama is installed and running (ollama.com), and that you've pulled the model (e.g. `ollama pull \(model)`).")
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw LLMError.http(status, LLMHTTP.errorMessage(from: data)) }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        let text = decoded.message.content
        guard !text.isEmpty else { throw LLMError.empty }
        return text
    }

    private struct Response: Decodable {
        let message: Message
        struct Message: Decodable { let content: String }
    }
}
