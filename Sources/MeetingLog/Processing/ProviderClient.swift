import Foundation

struct ProviderClient {
    let baseURL: String
    let apiKey: String
    let model: String

    var endpoint: URL {
        get throws {
            guard let root = URL(string: baseURL), root.scheme == "https", root.host != nil else {
                throw ProviderError.configuration("Provider URL must be a valid HTTPS URL.")
            }
            return root.appending(path: "chat/completions")
        }
    }

    func verifyConfiguration() async throws {
        _ = try await complete(prompt: "Reply with OK.")
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
        try await send(ChatRequest(
            model: model,
            messages: [.init(role: "user", content: [.text(prompt)])],
            temperature: 0
        ))
    }

    private func send(_ body: ChatRequest) async throws -> String {
        var request = URLRequest(url: try endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.authentication }
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw ProviderError.request(message)
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw ProviderError.invalidResponse
        }
        return content
    }
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

enum ProviderError: LocalizedError {
    case configuration(String)
    case invalidResponse
    case authentication
    case request(String)

    var errorDescription: String? {
        switch self {
        case let .configuration(message), let .request(message): message
        case .invalidResponse: "The provider returned an invalid response."
        case .authentication: "The provider rejected the API key."
        }
    }
}
