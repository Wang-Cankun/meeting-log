import Foundation

/// Azure Speech fast transcription with MAI-Transcribe-2. One request covers a whole recording or track,
/// so diarized speaker letters stay consistent for the whole section instead of restarting every ten minutes.
struct SpeechTranscriber: Sendable {
    static let model = "MAI-Transcribe-2"
    /// Each request uploads a whole recording or window, so fewer run at once than chat transcription.
    static let concurrencyLimit = 3
    let endpoint: String
    let apiKey: String
    var session: URLSession = ProviderClient.longRequestSession

    var url: URL {
        get throws {
            let root = endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let base = URL(string: root), base.scheme == "https", base.host != nil,
                  let url = URL(string: root + "/speechtotext/transcriptions:transcribe?api-version=2025-10-15") else {
                throw ProviderError.configuration("Speech endpoint must be a valid HTTPS URL.")
            }
            return url
        }
    }

    func verifyConfiguration() async throws {
        let silence = FileManager.default.temporaryDirectory.appending(path: "speech-check-\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: silence) }
        try MediaProcessor.encodeSilence(seconds: 1, destination: silence)
        _ = try await transcribe(audio: silence, diarize: true, phrases: [])
    }

    func transcribe(audio: URL, diarize: Bool, phrases: [String]) async throws -> SpeechResult {
        var definition: [String: Any] = [
            "enhancedMode": ["enabled": true, "model": Self.model, "modelOptions": ["timestamps": "segment", "transcribeStyle": "clean"]]
        ]
        if diarize { definition["diarization"] = ["enabled": true] }
        if !phrases.isEmpty { definition["phraseList"] = ["phrases": phrases] }
        let boundary = UUID().uuidString
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"definition\"\r\n\r\n".utf8))
        body.append(try JSONSerialization.data(withJSONObject: definition))
        body.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"audio.flac\"\r\nContent-Type: audio/flac\r\n\r\n".utf8))
        body.append(try Data(contentsOf: audio))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let upload = body

        return try await ProviderRetry.run {
            var request = URLRequest(url: try url)
            request.httpMethod = "POST"
            request.setValue(apiKey, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.upload(for: request, from: upload)
            guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 401 || http.statusCode == 403 { throw SpeechError.authentication }
                let body = String(decoding: data.prefix(300), as: UTF8.self)
                // A slow upload is reported as a 400 form error; it is a timeout and worth retrying.
                let status = http.statusCode == 400 && body.contains("MinRequestBodyDataRate") ? 408 : http.statusCode
                throw ProviderError.http(status: status,
                                         message: "Speech transcription failed (HTTP \(http.statusCode)): \(body)",
                                         retryAfter: ProviderRetry.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
            }
            guard let result = try? JSONDecoder().decode(SpeechResult.self, from: data) else { throw ProviderError.invalidResponse }
            return result
        }
    }

    /// Converts diarized phrases into validated transcript turns for one section.
    /// Speaker letters follow first appearance; the microphone track is always Me.
    static func transcript(_ result: SpeechResult, start: Double, end: Double, track: TranscriptTrack?) throws -> String {
        let phrases = result.phrases
            .map { SpeechResult.Phrase(speaker: $0.speaker, offsetMilliseconds: $0.offsetMilliseconds,
                                       text: $0.text.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }
            .sorted { $0.offsetMilliseconds < $1.offsetMilliseconds }
        guard !phrases.isEmpty else {
            return "[\(clock(Int(start)))] \(track == .microphone ? "Me" : "Speaker"): [no audible speech]"
        }
        // A response whose phrases all share one offset lost its timing; accepting it would stamp every turn at one time.
        if phrases.count > 1, Set(phrases.map(\.offsetMilliseconds)).count == 1 { throw SpeechError.missingTiming }
        if let last = phrases.last, Double(last.offsetMilliseconds) / 1000 > end - start + 1 { throw SpeechError.missingTiming }

        let latest = Int(end.rounded(.up)) - 1
        var letters: [Int?: String] = [:]
        var turns: [(time: Int, label: String, text: String)] = []
        for phrase in phrases {
            let label: String
            if track == .microphone {
                label = "Me"
            } else if let known = letters[phrase.speaker] {
                label = known
            } else {
                let index = letters.count
                label = index < 26 ? "Speaker \(Character(UnicodeScalar(65 + index)!))" : "Speaker \(index + 1)"
                letters[phrase.speaker] = label
            }
            let time = max(Int(start), min(Int(start + Double(phrase.offsetMilliseconds) / 1000), latest))
            if let last = turns.last, last.label == label {
                turns[turns.count - 1].text += " " + phrase.text
            } else {
                turns.append((time, label, phrase.text))
            }
        }
        let text = turns.map { "[\(clock($0.time))] \($0.label): \($0.text)" }.joined(separator: "\n")
        return try TranscriptResponse.validate(text, start: start, end: end)
    }

    /// Names from context tables and terminology bullets bias recognition; they are hints, not forced output.
    /// Earlier entries win when the list is capped, so callers pass the most specific context first.
    static func phrases(fromContext context: String) -> [String] {
        var result: [String] = []
        var inTerms = false
        for rawLine in context.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") {
                inTerms = line.localizedCaseInsensitiveContains("term")
                continue
            }
            if line.hasPrefix("|") {
                let cell = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().first
                    .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                guard !cell.isEmpty, !cell.allSatisfy({ "-: ".contains($0) }),
                      !["name", "term", "preferred term", "subproject", "full name"].contains(cell.lowercased()) else { continue }
                result += cell.components(separatedBy: CharacterSet(charactersIn: "(),/"))
            } else if inTerms, line.hasPrefix("- ") {
                result += line.dropFirst(2).components(separatedBy: CharacterSet(charactersIn: ";,()"))
            }
        }
        var seen = Set<String>()
        return result
            .map { $0.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) }
            .filter { (2...40).contains($0.count) && seen.insert($0.lowercased()).inserted }
            .prefix(100).map { $0 }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct SpeechResult: Decodable, Sendable {
    struct Phrase: Decodable, Sendable {
        let speaker: Int?
        let offsetMilliseconds: Int
        let text: String
    }
    let phrases: [Phrase]

    init(from decoder: Decoder) throws {
        // Silent audio may omit the phrase list entirely.
        phrases = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent([Phrase].self, forKey: .phrases) ?? []
    }

    private enum CodingKeys: String, CodingKey { case phrases }
}

enum SpeechError: LocalizedError {
    case authentication
    case missingTiming

    var errorDescription: String? {
        switch self {
        case .authentication: "Azure Speech rejected the speech key. Update the Speech endpoint and key in Settings."
        case .missingTiming: "Speech transcription returned phrases without usable timestamps."
        }
    }
}
