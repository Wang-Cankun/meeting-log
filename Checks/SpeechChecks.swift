import Synchronization
import AVFoundation
import Foundation

/// Speech-service transcription sends one diarized request per recording and falls back to windows for a long failure.
@MainActor
func checkSpeechTranscription() async throws {
    let decoded = try JSONDecoder().decode(SpeechResult.self, from: Data("""
    {"phrases":[{"speaker":3,"offsetMilliseconds":1200,"text":"Hello team."},
                {"speaker":1,"offsetMilliseconds":4000,"text":"Hi."},
                {"speaker":3,"offsetMilliseconds":7000,"text":"Let's start."},
                {"speaker":3,"offsetMilliseconds":9000,"text":"Agenda\\nfirst."},
                {"speaker":1,"offsetMilliseconds":19900,"text":"Late."}]}
    """.utf8))
    let text = try SpeechTranscriber.transcript(decoded, start: 0, end: 20, track: nil).text
    precondition(text == "[00:01] Speaker A: Hello team.\n\n[00:04] Speaker B: Hi.\n\n[00:07] Speaker A: Let's start. Agenda first.\n\n[00:19] Speaker B: Late.", text)
    let offset = try SpeechTranscriber.transcript(decoded, start: 600, end: 620, track: .microphone).text
    precondition(offset == "[10:01] Speaker A: Hello team.\n\n[10:04] Speaker B: Hi.\n\n[10:07] Speaker A: Let's start.\n\n[10:09] Speaker A: Agenda first.\n\n[10:19] Speaker B: Late.",
                 "Microphone phrases keep speaker letters and individual times before rendering: \(offset)")
    let silent = try JSONDecoder().decode(SpeechResult.self, from: Data("{}".utf8))
    let silence = try SpeechTranscriber.transcript(silent, start: 0, end: 5, track: nil).text
    precondition(silence == "[00:00] Speaker: [no audible speech]")
    let microphoneSilence = try SpeechTranscriber.transcript(silent, start: 0, end: 5, track: .microphone).text
    precondition(microphoneSilence == "[00:00] Speaker: [no audible speech]")
    let untimed = try JSONDecoder().decode(SpeechResult.self, from: Data("""
    {"phrases":[{"speaker":0,"offsetMilliseconds":0,"text":"One."},{"speaker":1,"offsetMilliseconds":0,"text":"Two."}]}
    """.utf8))
    do {
        _ = try SpeechTranscriber.transcript(untimed, start: 0, end: 600, track: nil)
        preconditionFailure("Phrases without timing accepted")
    } catch SpeechError.missingTiming {}

    let overrun = try JSONDecoder().decode(SpeechResult.self, from: Data("""
    {"phrases":[{"speaker":0,"offsetMilliseconds":20400,"durationMilliseconds":600,"text":"Late.\\nStill here."}]}
    """.utf8))
    let clamped = try SpeechTranscriber.transcript(overrun, start: 0, end: 20, track: .system)
    let validated = try TranscriptResponse.validate(clamped.text, start: 0, end: 20)
    precondition(validated == "[00:19] Speaker A: Late. Still here.", validated)
    precondition(clamped.turns[0].startMilliseconds == 19_999 && clamped.turns[0].durationMilliseconds == 600,
                 "Clamping preserves the final second and phrase duration")

    let tidy = TranscriptPolisher.tidy("""
    # Transcript

    ## 00:00–01:00

    [00:01] Speaker A: Um... I think we should, uh, start

    [00:03] Speaker B: Mm-hmm.

    [00:04] Speaker A: with the QC part.

    [00:06] Speaker B: Did you run it?

    [00:08] Speaker A: Yeah.

    [00:09] Speaker B: Uh-huh. Great, 呃，那我们继续。

    [00:12] Speaker A: Uh.

    [00:14] Speaker B: Next.
    """)
    precondition(tidy == """
    # Transcript

    ## 00:00–01:00

    [00:01] Speaker A: I think we should start with the QC part.

    [00:06] Speaker B: Did you run it?

    [00:08] Speaker A: Yeah.

    [00:09] Speaker B: Uh-huh. Great, 那我们继续。 Next.

    """, tidy)

    let phrases = SpeechTranscriber.phrases(fromContext: """
    # Context
    | Name | Background |
    | --- | --- |
    | Cankun Wang (Cankun) | Builder |
    | Reza | Postdoc |
    ## Terms
    - Xenium, TMA (tissue microarray); H5AD.
    """)
    precondition(phrases == ["Cankun Wang", "Cankun", "Reza", "Xenium", "TMA", "tissue microarray", "H5AD"], "\(phrases)")

    let root = FileManager.default.temporaryDirectory.appending(path: "speech-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let project = try store.createProject(named: "Speech")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpeechFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let provider = ProviderClient(baseURL: "https://chat.invalid/v1", apiKey: "fixture", model: "fixture", session: session)
    let speech = SpeechTranscriber(endpoint: "https://speech.invalid/", apiKey: "fixture", session: session)

    // In-person capture: empty computer audio, so the whole microphone recording is one diarized request.
    let (inPerson, inPersonManifest) = try store.createPendingSession(videoEnabled: false, microphoneID: "fixture")
    try writeSpeechTone(to: inPerson.appending(path: "system-audio.caf"), seconds: 0)
    try writeSpeechTone(to: inPerson.appending(path: "microphone.m4a"), seconds: 20)
    let inPersonPreparation = try await CapturePreparation.prepare(in: inPerson)
    precondition(inPersonPreparation.mode == .microphoneOnly)
    SpeechFixture.reset(failFirstSpeech: false)
    let speechStages = StageRecorder()
    let archived = try await MeetingProcessor(store: store, client: provider, speech: speech, progress: { speechStages.record($0) })
        .process(directory: inPerson, manifest: inPersonManifest, projectName: project.name)
    speechStages.verifyCompletePipeline()
    var state = SpeechFixture.snapshot()
    precondition(state.speechRequests == 1 && state.diarized == 1 && state.flacUploads == 1, "\(state)")
    precondition(state.temperatureRejections > 0, "Rejected temperature must be retried without it")
    let raw = try String(contentsOf: archived.appending(path: "transcript_raw.md"), encoding: .utf8)
    precondition(raw.components(separatedBy: "\n## ").count == 2, "One request yields one section: \(raw)")
    precondition(raw.contains("[00:01] Speaker A: Opening.\n\n[00:05] Speaker B: Reply."), raw)
    let readable = try String(contentsOf: archived.appending(path: "transcript.md"), encoding: .utf8)
    precondition(readable.contains("[00:01] Speaker A: Opening.\n\n[00:05] Speaker B: Reply."), readable)
    precondition(SpeechFixture.snapshot().cleanupRequests == 0, "Speech transcripts use local cleanup")
    let provenance = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: archived.appending(path: "summary-provenance.json")))
    precondition(provenance["transcription"]?.hasPrefix(SpeechTranscriber.model) == true)

    // A long recording whose whole-file request fails is retried as overlapping ten-minute windows.
    let (long, longManifest) = try store.createPendingSession(videoEnabled: false, microphoneID: "fixture")
    try writeSpeechTone(to: long.appending(path: "system-audio.caf"), seconds: 0)
    try writeSpeechTone(to: long.appending(path: "microphone.m4a"), seconds: 960)
    _ = try await CapturePreparation.prepare(in: long)
    SpeechFixture.reset(failFirstSpeech: true)
    let longArchive = try await MeetingProcessor(store: store, client: provider, speech: speech)
        .process(directory: long, manifest: longManifest, projectName: project.name)
    state = SpeechFixture.snapshot()
    precondition(state.speechRequests == 3, "One failed whole-file request plus two windows: \(state)")
    let longRaw = try String(contentsOf: longArchive.appending(path: "transcript_raw.md"), encoding: .utf8)
    precondition(longRaw.contains("## 00:00–10:00") && longRaw.contains("## 09:50–16:00"), longRaw)

    // A completed sibling must retain its turns when the failed track is split and reindexed.
    let (fallback, fallbackManifest) = try store.createPendingSession(videoEnabled: false, microphoneID: "fixture")
    try writeSpeechTone(to: fallback.appending(path: "system-audio.caf"), seconds: 960)
    try FileManager.default.copyItem(at: longArchive.appending(path: "audio.m4a"), to: fallback.appending(path: "microphone.m4a"))
    _ = try await CapturePreparation.prepare(in: fallback)
    SpeechFixture.reset(failFirstSpeech: true)
    let checkpoints = Mutex<[Data]>([])
    _ = try await MeetingProcessor(store: store, client: nil, speech: speech, progress: { progress in
        if case let .transcribe(_, total) = progress.stage, total == 3,
           let data = try? Data(contentsOf: fallback.appending(path: "coverage.json")) {
            checkpoints.withLock { $0.append(data) }
        }
    }).process(directory: fallback, manifest: fallbackManifest, projectName: project.name)
    state = SpeechFixture.snapshot()
    precondition(state.speechRequests == 4 && state.diarized == 4,
                 "Both capture tracks and the two fallback windows must request diarization: \(state)")
    guard let splitData = checkpoints.withLock({ $0.first }) else { preconditionFailure("Missing split checkpoint") }
    let split = try JSONDecoder().decode([TranscriptBlock].self, from: splitData)
    guard let completed = split.first(where: { $0.status == .complete }) else { preconditionFailure("Lost completed sibling") }
    precondition(split.count == 3 && completed.endSeconds > 900)
    precondition(completed.resolvedTurns[0].startMilliseconds == 1200 && completed.resolvedTurns[0].durationMilliseconds == 700,
                 "Completed speech turns must survive checkpoint writes and fallback reindexing")

    let legacyURL = root.appending(path: "coverage.json")
    try Data("""
    [{"id":0,"startSeconds":0,"endSeconds":20,"status":"complete","text":"[00:12] Speaker A: Cached."}]
    """.utf8).write(to: legacyURL)
    let legacy = try JSONDecoder().decode([TranscriptBlock].self, from: Data(contentsOf: legacyURL))
    precondition(legacy[0].turns == nil && legacy[0].status == .complete)
    precondition(legacy[0].resolvedTurns[0].startMilliseconds == 12_000 && legacy[0].resolvedTurns[0].text == "Cached.",
                 "Coverage without structured turns must decode and resolve its text")
    print("Speech turn metadata passed: millisecond clamp, durations, fallback checkpoints, legacy coverage")
    print("Speech transcription passed: diarized letters and microphone, timing guard, context phrases, whole-file request, window fallback, temperature retry")
}

/// With AI summaries off, the processor archives Azure Speech transcripts without any chat request.
@MainActor
func checkTranscriptOnlyProcessing() async throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "transcript-only-processing-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    let store = ArchiveStore(root: root)
    let project = try store.createProject(named: "Speech")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SpeechFixture.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let speech = SpeechTranscriber(endpoint: "https://speech.invalid/", apiKey: "fixture", session: session)

    let (directory, manifest) = try store.createPendingSession(videoEnabled: false, microphoneID: "fixture")
    try writeSpeechTone(to: directory.appending(path: "system-audio.caf"), seconds: 0)
    try writeSpeechTone(to: directory.appending(path: "microphone.m4a"), seconds: 20)
    _ = try await CapturePreparation.prepare(in: directory)
    SpeechFixture.reset(failFirstSpeech: false)
    let recorder = StageRecorder()
    let archived = try await MeetingProcessor(store: store, client: nil, speech: speech, progress: { recorder.record($0) })
        .process(directory: directory, manifest: manifest, projectName: project.name)
    let state = SpeechFixture.snapshot()
    precondition(state.speechRequests == 1 && state.chatRequests == 0, "Transcript-only processing must not contact a language model: \(state)")
    let stages = recorder.stages
    precondition(stages.first == .prepare && stages.contains(.clean) && stages.last == .complete, "\(stages)")
    precondition(!stages.contains { [ProcessingStage.summary, .evidence, .chinese].contains($0) }, "\(stages)")
    let expected = "\(ArchiveStore.timestamp.string(from: manifest.startedAt))-\(ArchiveStore.transcriptOnlyTitle(for: manifest))"
    precondition(archived.lastPathComponent == expected, archived.lastPathComponent)
    for name in ["audio.m4a", "transcript_raw.md", "transcript.md"] {
        precondition(fm.fileExists(atPath: archived.appending(path: name).path), "Missing \(name)")
    }
    for name in ["summary.md", "summary_cn.md", "summary-provenance.json", "coverage.json", "session.json", "chunks"] {
        precondition(!fm.fileExists(atPath: archived.appending(path: name).path), "Unexpected \(name)")
    }
    let readable = try String(contentsOf: archived.appending(path: "transcript.md"), encoding: .utf8)
    precondition(readable.contains("[00:01] Speaker A: Opening."), readable)

    // Nothing can transcribe without a speech service or a model; the recording must stay pending.
    let (orphan, orphanManifest) = try store.createPendingSession(videoEnabled: false, microphoneID: nil)
    try writeSpeechTone(to: orphan.appending(path: "original.m4a"), seconds: 2)
    do {
        _ = try await MeetingProcessor(store: store, client: nil)
            .process(directory: orphan, manifest: orphanManifest, projectName: project.name)
        preconditionFailure("Processing without any service accepted")
    } catch ProviderError.configuration {}
    let pending = try store.pendingSessions()
    precondition(pending.contains { $0.1.id == orphanManifest.id && $0.1.status == .failed })
    precondition(fm.fileExists(atPath: orphan.appending(path: "original.m4a").path))
    print("Transcript-only processing passed: speech only, no chat requests, transcript archive, missing-service failure")
}

private func writeSpeechTone(to url: URL, seconds: Int) throws {
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let settings: [String: Any] = url.pathExtension == "m4a"
        ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1]
        : format.settings
    let file = try AVAudioFile(forWriting: url, settings: settings)
    guard seconds > 0 else { return }
    let frames = AVAudioFrameCount(24_000 * seconds)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
    buffer.frameLength = frames
    for index in 0..<Int(frames) {
        buffer.floatChannelData![0][index] = 0.1 * sin(Float(index) * 2 * .pi * 440 / 24_000)
    }
    try file.write(from: buffer)
}

private final class SpeechFixture: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var failFirstSpeech = false
        var speechRequests = 0
        var diarized = 0
        var flacUploads = 0
        var temperatureRejections = 0
        var cleanupRequests = 0
        var chatRequests = 0
    }
    private static let state = Mutex(State())
    static func reset(failFirstSpeech: Bool) { state.withLock { $0 = State(failFirstSpeech: failFirstSpeech) } }
    static func snapshot() -> State { state.withLock { $0 } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        if request.url!.path.contains("speechtotext") {
            let fail = Self.state.withLock { state -> Bool in
                state.speechRequests += 1
                if data.range(of: Data("\"diarization\"".utf8)) != nil { state.diarized += 1 }
                if data.range(of: Data("fLaC".utf8)) != nil { state.flacUploads += 1 }
                return state.failFirstSpeech && state.speechRequests == 1
            }
            if fail { return respond(400, #"{"error":"diarization_unavailable"}"#) }
            return respond(200, #"{"phrases":[{"speaker":0,"offsetMilliseconds":1200,"durationMilliseconds":700,"text":"Opening."},{"speaker":2,"offsetMilliseconds":5000,"text":"Reply."}]}"#)
        }
        Self.state.withLock { $0.chatRequests += 1 }
        let body = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        if body["temperature"] != nil {
            Self.state.withLock { $0.temperatureRejections += 1 }
            return respond(400, #"{"error":{"message":"Unsupported value: 'temperature' does not support 0 with this model.","code":"unsupported_value"}}"#)
        }
        let parts = (body["messages"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        let prompt = parts.first { $0["type"] as? String == "text" }!["text"] as! String
        let content: String
        if prompt.contains("CLEAN_TRANSCRIPT") {
            Self.state.withLock { $0.cleanupRequests += 1 }
            let raw = prompt.components(separatedBy: "<raw_transcript>\n")[1].components(separatedBy: "\n</raw_transcript>")[0]
            content = String(data: try! JSONSerialization.data(withJSONObject: ["transcript": raw]), encoding: .utf8)!
        } else if prompt.contains("CHINESE_SUMMARY") {
            content = ##"{"folderTitle":"语音测试","markdown":"# 语音测试\n\n## 摘要\n\n测试。"}"##
        } else {
            content = #"{"title":"Speech fixture","projectName":"Speech","summary":["Fixture."],"actionItems":[],"decisions":[],"keyTopics":[]}"#
        }
        respond(200, String(data: try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content]]]]), encoding: .utf8)!)
    }

    private func respond(_ status: Int, _ body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
