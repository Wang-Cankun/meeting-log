import Foundation
import ObjectiveC
import Synchronization

func checkProviderSetup() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SettingsFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = ProviderClient(baseURL: "https://settings.invalid/v1", apiKey: "fixture", model: "audio-model", session: session)
    try await client.verifyConfiguration()
    print("Provider setup passed: connection probe satisfies the JSON request contract")
}

final class SettingsFixture: URLProtocol, @unchecked Sendable {
    struct State {
        var rejectSpeech = false
        var requests: [String] = []
    }
    static let state = Mutex(State())

    // URLSession snapshots its protocol classes; global URLProtocol registration does not intercept it.
    static func interceptDefaultSessions() -> () -> Void {
        let original = class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.default))!
        let fixture = class_getClassMethod(SettingsSessionConfiguration.self, #selector(SettingsSessionConfiguration.make))!
        method_exchangeImplementations(original, fixture)
        return { method_exchangeImplementations(original, fixture) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "settings.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream, data.isEmpty {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        if request.url!.path.contains("speechtotext") {
            precondition(data.range(of: Data("fLaC".utf8)) != nil, "Speech verification must upload real FLAC")
            let rejected = Self.state.withLock {
                $0.requests.append("speech")
                return $0.rejectSpeech
            }
            return respond(rejected ? 401 : 200, rejected ? "{}" : #"{"phrases":[]}"#)
        }
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let parts = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        let prompt = parts.first { $0["type"] as? String == "text" }!["text"] as! String
        let hasAudio = parts.contains { $0["type"] as? String == "input_audio" }
        Self.state.withLock { $0.requests.append(hasAudio ? "audio" : "text") }
        if hasAudio {
            if body["model"] as? String == "text-only" {
                return respond(400, #"{"error":{"message":"This model does not support input_audio."}}"#)
            }
            let audio = parts.first { $0["type"] as? String == "input_audio" }!["input_audio"] as! [String: String]
            precondition(audio["format"] == "m4a" && !(Data(base64Encoded: audio["data"]!)?.isEmpty ?? true))
        } else if (body["response_format"] as? [String: String])?["type"] == "json_object",
                  !prompt.localizedCaseInsensitiveContains("json") {
            return respond(400, #"{"error":{"message":"messages must contain the word JSON for json_object."}}"#)
        }
        let content: String
        if hasAudio {
            let range = prompt.range(of: #"(?<=covers )\d+:\d+"#, options: .regularExpression)
            let start = range.map { String(prompt[$0]) } ?? "00:00"
            content = "[\(start)] Speaker: [no audible speech]"
        } else if prompt.contains("CHINESE_SUMMARY") {
            content = ##"{"folderTitle":"设置测试","markdown":"# 设置测试\n\n## 摘要\n\n无语音。"}"##
        } else if prompt.contains("CLEAN_TRANSCRIPT") {
            let raw = prompt.components(separatedBy: "<raw_transcript>\n")[1].components(separatedBy: "\n</raw_transcript>")[0]
            content = String(data: try! JSONSerialization.data(withJSONObject: ["transcript": raw]), encoding: .utf8)!
        } else if prompt.contains("Reply") {
            content = #"{"ok":true}"#
        } else {
            content = #"{"title":"Settings fixture","projectName":"Inbox","summary":[],"actionItems":[],"decisions":[],"keyTopics":[]}"#
        }
        let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        respond(200, String(decoding: response, as: UTF8.self))
    }

    private func respond(_ status: Int, _ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SettingsSessionConfiguration: NSObject {
    @objc static func make() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsFixture.self]
        return configuration
    }
}
