import Foundation

struct ProviderClient: Sendable {
    let baseURL: String
    let apiKey: String
    let model: String
    var session: URLSession = .shared

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
        try await ProviderRetry.run { try await sendOnce(body) }
    }

    private func sendOnce(_ body: ChatRequest) async throws -> String {
        var request = URLRequest(url: try endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.authentication }
            let message = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw ProviderError.http(status: http.statusCode, message: message, retryAfter: ProviderRetry.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        }
        // Long requests can fail upstream after a 200 status; the body then carries an error instead of choices.
        guard let decoded = try? JSONDecoder().decode(ChatResponse.self, from: data) else { throw ProviderError.invalidResponse }
        if let error = decoded.error ?? decoded.choices?.first?.error {
            throw ProviderError.http(status: error.code ?? 502, message: error.message, retryAfter: nil)
        }
        let choice = decoded.choices?.first
        if choice?.finish_reason == "length" {
            throw ProviderError.request("The provider truncated its output. Retry with a model that supports a longer response.")
        }
        guard let content = choice?.message?.content, !content.isEmpty else {
            throw ProviderError.emptyResponse(finishReason: choice?.finish_reason)
        }
        return content
    }
}

private struct ChatRequest: Encodable, Sendable {
    struct Message: Encodable, Sendable {
        let role: String
        let content: [Content]
    }

    enum Content: Encodable, Sendable {
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
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
        let finish_reason: String?
        let error: APIError?
    }
    let choices: [Choice]?
    let error: APIError?
}

private struct APIError: Decodable {
    let message: String
    let code: Int?

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        message = try values.decode(String.self, forKey: .message)
        // Providers send numeric or string codes; only numeric HTTP-like codes drive retries.
        code = (try? values.decode(Int.self, forKey: .code)) ?? (try? values.decode(String.self, forKey: .code)).flatMap(Int.init)
    }

    private enum CodingKeys: String, CodingKey { case message, code }
}

private struct APIErrorEnvelope: Decodable {
    let error: APIError
}

enum ProviderError: LocalizedError {
    case configuration(String)
    case invalidResponse
    case authentication
    case request(String)
    case http(status: Int, message: String, retryAfter: TimeInterval?)
    case emptyResponse(finishReason: String?)

    var errorDescription: String? {
        switch self {
        case let .configuration(message), let .request(message): message
        case let .http(_, message, _): message
        case .invalidResponse: "The provider returned an invalid response."
        case .authentication: "The provider rejected the API key."
        case let .emptyResponse(reason): "The provider returned no text\(reason.map { " (finish reason: \($0))" } ?? ""). Retry later."
        }
    }
}


enum ProviderRetry {
    static func run<T: Sendable>(
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do { return try await operation() } catch {
                guard attempt < 2, let delay = delay(for: error, attempt: attempt) else { throw error }
                try await sleep(delay)
            }
        }
        throw ProviderError.invalidResponse
    }

    static func delay(for error: Error, attempt: Int) -> TimeInterval? {
        let backoff = pow(2.0, Double(attempt + 1))
        if case let ProviderError.http(status, _, retryAfter) = error,
           status == 429 || status == 408 || (500...599).contains(status) {
            return max(backoff, retryAfter ?? 0)
        }
        if case ProviderError.emptyResponse = error { return backoff }
        if let error = error as? URLError,
           [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
            return backoff
        }
        return nil
    }

    static func retryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value.trimmingCharacters(in: .whitespaces)), seconds.isFinite {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
