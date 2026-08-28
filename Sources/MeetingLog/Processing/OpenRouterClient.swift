import Foundation

struct OpenRouterModel: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
}

struct OpenRouterClient {
    static let defaultModel = "google/gemini-3.7-flash"
    private static let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    let apiKey: String
    let model: String

    func verifyKey() async throws {
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw http.statusCode == 401 || http.statusCode == 403
                ? OpenRouterError.authentication
                : OpenRouterError.request("OpenRouter returned HTTP \(http.statusCode).")
        }
    }

    static func availableAudioModels() async throws -> [OpenRouterModel] {
        let url = URL(string: "https://openrouter.ai/api/v1/models?input_modalities=audio&output_modalities=text")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw OpenRouterError.invalidResponse
        }
        return try JSONDecoder().decode(ModelEnvelope.self, from: data).data
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func transcribe(audio: URL, prompt: String) async throws -> String {
        let body = ChatRequest(
            model: model,
            messages: [.init(role: "user", content: [
                .text(prompt),
                .audio(try Data(contentsOf: audio).base64EncodedString(), audio.pathExtension.lowercased()),
            ])],
            temperature: 0
        )
        return try await send(body)
    }

    func complete(prompt: String) async throws -> String {
        let body = ChatRequest(
            model: model,
            messages: [.init(role: "user", content: [.text(prompt)])],
            temperature: 0
        )
        return try await send(body)
    }

    private func send(_ body: ChatRequest) async throws -> String {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MeetingLog", forHTTPHeaderField: "X-OpenRouter-Title")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OpenRouterError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw OpenRouterError.authentication }
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw OpenRouterError.request(message)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw OpenRouterError.invalidResponse
        }
        return content
    }
}

private struct ModelEnvelope: Decodable {
    let data: [OpenRouterModel]
}

private struct ChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: [Content]
    }

    enum Content: Encodable {
        case text(String)
        case audio(String, String)

        func encode(to encoder: Encoder) throws {
            var value = encoder.container(keyedBy: Keys.self)
            switch self {
            case let .text(text):
                try value.encode("text", forKey: .type)
                try value.encode(text, forKey: .text)
            case let .audio(data, format):
                try value.encode("input_audio", forKey: .type)
                try value.encode(Audio(data: data, format: format), forKey: .inputAudio)
            }
        }

        private struct Audio: Encodable { let data: String; let format: String }
        private enum Keys: String, CodingKey { case type, text; case inputAudio = "input_audio" }
    }

    let model: String
    let messages: [Message]
    let temperature: Double
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable { struct Message: Decodable { let content: String }; let message: Message }
    let choices: [Choice]
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError
}

enum OpenRouterError: LocalizedError {
    case invalidResponse
    case authentication
    case request(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "OpenRouter returned an invalid response."
        case .authentication: "OpenRouter rejected the saved API key."
        case let .request(message): message
        }
    }
}
