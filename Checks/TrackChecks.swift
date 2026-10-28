import Synchronization
import AVFoundation
import Foundation

/// A complete capture transcribes microphone and computer audio separately and labels the microphone Me.
@MainActor
func checkSeparateTrackTranscription() async throws {
    let merged = MarkdownRenderer.merged([
        TranscriptBlock(id: 0, startSeconds: 0, endSeconds: 600, track: .system, status: .complete,
                        text: "[00:02] Speaker A: Can you hear me?\n\n[00:09] Speaker B: Next item."),
        TranscriptBlock(id: 1, startSeconds: 0, endSeconds: 600, track: .microphone, status: .complete,
                        text: "[00:05] Speaker A: Yes, clearly."),
    ])
    precondition(merged == "[00:02] Speaker A: Can you hear me?\n\n[00:05] Me: Yes, clearly.\n\n[00:09] Speaker B: Next item.")
    let silent = MarkdownRenderer.merged([
        TranscriptBlock(id: 0, startSeconds: 0, endSeconds: 600, track: .system, status: .complete, text: "[00:00] Speaker: [no audible speech]"),
        TranscriptBlock(id: 1, startSeconds: 0, endSeconds: 600, track: .microphone, status: .complete, text: "[00:03] Me: Hello?"),
    ])
    precondition(silent == "[00:03] Me: Hello?", "Silence placeholders must not interleave with speech")
    let remote = try JSONDecoder().decode(SpeechResult.self, from: Data("""
    {"phrases":[{"speaker":0,"offsetMilliseconds":2000,"text":"Is the rough placement good enough?"},
                {"speaker":0,"offsetMilliseconds":20000,"text":"Okay, nice."}]}
    """.utf8))
    let local = try JSONDecoder().decode(SpeechResult.self, from: Data("""
    {"phrases":[{"speaker":0,"offsetMilliseconds":1000,"text":"Here is step two."},
                {"speaker":0,"offsetMilliseconds":10000,"text":"Mostly, yes."},
                {"speaker":0,"offsetMilliseconds":12000,"text":"Twocan fixes the rest."}]}
    """.utf8))
    let answered = MarkdownRenderer.merged([
        TranscriptBlock(id: 0, startSeconds: 0, endSeconds: 600, track: .system, status: .complete,
                        text: try SpeechTranscriber.transcript(remote, start: 0, end: 600, track: .system)),
        TranscriptBlock(id: 1, startSeconds: 0, endSeconds: 600, track: .microphone, status: .complete,
                        text: try SpeechTranscriber.transcript(local, start: 0, end: 600, track: .microphone)),
    ])
    precondition(answered == """
    [00:01] Me: Here is step two.

    [00:02] Speaker A: Is the rough placement good enough?

    [00:10] Me: Mostly, yes.

    [00:12] Me: Twocan fixes the rest.

    [00:20] Speaker A: Okay, nice.
    """, "An answer must stay between the question and the reply that follow it on the other track: \(answered)")
    let readable = TranscriptPolisher.tidy("## 00:00–10:00\n\n" + answered)
    precondition(readable.contains("[00:10] Me: Mostly, yes. Twocan fixes the rest."), "The readable transcript joins a speaker's adjacent turns: \(readable)")
    let monologue = try JSONDecoder().decode(SpeechResult.self, from: Data("""
    {"phrases":[{"speaker":0,"offsetMilliseconds":1000,"text":"First slide."},
                {"speaker":0,"offsetMilliseconds":240000,"text":"Fifth slide."},
                {"speaker":0,"offsetMilliseconds":540000,"text":"Questions?"}]}
    """.utf8))
    let presented = MarkdownRenderer.merged([
        TranscriptBlock(id: 0, startSeconds: 0, endSeconds: 600, track: .system, status: .complete, text: "[00:00] Speaker: [no audible speech]"),
        TranscriptBlock(id: 1, startSeconds: 0, endSeconds: 600, track: .microphone, status: .complete,
                        text: try SpeechTranscriber.transcript(monologue, start: 0, end: 600, track: .microphone)),
    ])
    precondition(presented == "[00:01] Me: First slide.\n\n[04:00] Me: Fifth slide.\n\n[09:00] Me: Questions?",
                 "A monologue keeps each phrase's time in the raw transcript: \(presented)")
    let accepted = TranscriptPolisher.tidy("""
    ## 00:00–01:00

    [00:01] Speaker A: Please send the table by Friday.

    [00:03] Me: Okay.

    [00:04] Speaker A: Then let's move on.
    """)
    precondition(accepted.contains("[00:03] Me: Okay."), "The recording user's short reply is not a backchannel: \(accepted)")
    let listened = TranscriptPolisher.tidy("""
    ## 00:00–01:00

    [00:01] Speaker A: The first batch failed.

    [00:05] Me: Mm-hmm.

    [00:06] Speaker A: So we reran it overnight.

    [00:09] Me: Mm, okay.

    [00:10] Speaker A: Please check the logs.

    [00:12] Me: 好的。

    [00:13] Speaker A: Thanks.
    """)
    precondition(listened.contains("[00:01] Speaker A: The first batch failed. So we reran it overnight.") && !listened.contains("Mm-hmm"),
                 "The recording user's wordless sound between one speaker's turns is a backchannel: \(listened)")
    precondition(listened.contains("[00:09] Me: Mm, okay.") && listened.contains("[00:12] Me: 好的。"),
                 "A Me turn with any assent word stays: \(listened)")
    let script = MarkdownRenderer.merged([
        TranscriptBlock(id: 0, startSeconds: 0, endSeconds: 600, status: .complete, text: "[00:01] Speaker A: 這個 GPU server 還要修。"),
    ])
    precondition(script == "[00:01] Speaker A: 这个 GPU server 还要修。", "Chinese must be Simplified; English stays unchanged")

    let root = FileManager.default.temporaryDirectory.appending(path: "track-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let project = try store.createProject(named: "Tracks")
    let (directory, manifest) = try store.createPendingSession(videoEnabled: false, microphoneID: "fixture")
    try writeTone(to: directory.appending(path: "system-audio.caf"), seconds: 20, fileType: .caf)
    try writeTone(to: directory.appending(path: "microphone.m4a"), seconds: 15, fileType: .m4a)
    let preparation = try await CapturePreparation.prepare(in: directory)
    precondition(preparation.mode == .complete)

    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TrackFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let provider = ProviderClient(baseURL: "https://tracks.invalid", apiKey: "fixture", model: "fixture", session: session)
    let stages = StageRecorder()
    let archived = try await MeetingProcessor(store: store, client: provider, progress: { stages.record($0) })
        .process(directory: directory, manifest: manifest, projectName: project.name)
    stages.verifyCompletePipeline()
    let raw = try String(contentsOf: archived.appending(path: "transcript_raw.md"), encoding: .utf8)
    precondition(raw.contains("Turns labeled Me come from the recording user's microphone."))
    precondition(raw.contains("[00:01] Speaker A: Remote update.\n\n[00:04] Me: Local reply."), raw)
    precondition(raw.components(separatedBy: "## ").count == 2, "Both tracks must share one section per window")
    precondition(FileManager.default.fileExists(atPath: archived.appending(path: "audio.m4a").path))
    precondition(!FileManager.default.fileExists(atPath: archived.appending(path: "microphone.m4a").path))
    print("Separate tracks passed: per-track upload, fixed Me label, timestamp merge, answer order, monologue times, Me replies and sounds, silence handling")
}

/// Collects structured processing progress from any isolation context.
final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ProcessingProgress] = []

    var stages: [ProcessingStage] { lock.withLock { values.map(\.stage) } }

    func record(_ progress: ProcessingProgress) {
        lock.withLock { values.append(progress) }
    }

    func verifyCompletePipeline() {
        let stages = stages
        precondition(stages.first == .prepare, "\(stages)")
        precondition(zip(stages, stages.dropFirst()).allSatisfy { $0.segment <= $1.segment }, "Stages regressed: \(stages)")
        precondition(stages.contains { if case let .transcribe(_, total) = $0 { total > 0 } else { false } }, "\(stages)")
        for stage in [ProcessingStage.clean, .summary, .evidence, .chinese] { precondition(stages.contains(stage), "\(stages)") }
        precondition(stages.last == .complete, "\(stages)")
        precondition(lock.withLock { values.allSatisfy { !$0.detail.isEmpty } })
    }
}

private func writeTone(to url: URL, seconds: Int, fileType: AVFileType) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    var settings = format.settings
    if fileType == .m4a {
        settings = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1]
    }
    let file = try AVAudioFile(forWriting: url, settings: settings)
    let frames = AVAudioFrameCount(24_000 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        buffer.floatChannelData![0][index] = 0.1 * sin(Float(index) * 2 * .pi * 440 / 24_000)
    }
    try file.write(from: buffer)
}

private final class TrackFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        let parts = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        let prompt = parts.first { $0["type"] as? String == "text" }!["text"] as! String
        let content: String
        if parts.contains(where: { $0["type"] as? String == "input_audio" }) {
            if prompt.contains("Source: the recording user's own microphone") {
                // The model's label is ignored; the track determines Me.
                content = "[00:04] Speaker A: Local reply."
            } else {
                precondition(prompt.contains("Source: the computer's audio output"))
                content = "[00:01] Speaker A: Remote update."
            }
        } else if prompt.contains("CLEAN_TRANSCRIPT") {
            let raw = prompt.components(separatedBy: "<raw_transcript>\n")[1].components(separatedBy: "\n</raw_transcript>")[0]
            content = String(data: try! JSONSerialization.data(withJSONObject: ["transcript": raw]), encoding: .utf8)!
        } else if prompt.contains("CHINESE_SUMMARY") {
            content = ##"{"folderTitle":"音轨测试","markdown":"# 音轨测试\n\n## 摘要\n\n测试。"}"##
        } else {
            content = #"{"title":"Track fixture","projectName":"Tracks","summary":["Fixture."],"actionItems":[],"decisions":[],"keyTopics":[]}"#
        }
        let response = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

func checkSummaryMarkdown() {
    let blocks = SummaryMarkdown.parse("""
    # Title

    ## Action items

    | Task | Owner | Deadline | Context / evidence |
    | --- | --- | --- | --- |
    | Send A &#124; B | Me | — | L3: “Send it.”<br>L9 [unverified reference]: “Soon.” |

    - Adopt plan
      Evidence: L12: “We agree.”
    1. First
    """)
    precondition(blocks == [
        .heading(level: 1, text: "Title"),
        .heading(level: 2, text: "Action items"),
        .table(header: ["Task", "Owner", "Deadline", "Context / evidence"],
               rows: [["Send A | B", "Me", "—", "L3: “Send it.”\nL9 [unverified reference]: “Soon.”"]]),
        .bullet(marker: "•", text: "Adopt plan", depth: 0),
        .detail(text: "Evidence: L12: “We agree.”", depth: 0),
        .bullet(marker: "1.", text: "First", depth: 0),
    ], "\(blocks)")
    let marks = SummaryInline.references(inMarkdown: "Evidence: L12: “HLA2 L3”, see URL1 and L4")
    precondition(marks.map(\.line) == [12, 4], "Quoted words and identifiers are not references: \(marks)")
    print("Summary Markdown passed: tables, continuation lines, numbered lists and references")
}

/// A 200 response whose body carries an upstream error must retry, not fail as undecodable data.
func checkInBodyProviderError() async throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [InBodyErrorFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let client = ProviderClient(baseURL: "https://in-body.invalid", apiKey: "fixture", model: "fixture", session: session)
    InBodyErrorFixture.requests.withLock { $0 = 0 }
    let text = try await client.complete(prompt: "Reply with OK.")
    precondition(text == "OK" && InBodyErrorFixture.requests.withLock { $0 } == 2)
    precondition(ProviderRetry.delay(for: ProviderError.emptyResponse(finishReason: nil), attempt: 0) != nil)
    print("Provider body errors passed: in-body upstream error retried, empty text retryable")
}

private final class InBodyErrorFixture: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let count = Self.requests.withLock { $0 += 1; return $0 }
        let body: [String: Any] = count == 1
            ? ["error": ["message": "Upstream provider failed", "code": 502]]
            : ["choices": [["message": ["content": "OK"], "finish_reason": "stop"]]]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
