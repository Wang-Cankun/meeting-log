import AVFoundation
import Foundation

@MainActor
func checkCapturePreparation() async throws {
    enum InjectedFailure: Error { case mix, crash }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appending(path: "capture-recovery-\(UUID())")
    defer { try? fm.removeItem(at: root) }
    try fm.createDirectory(at: root, withIntermediateDirectories: true)

    // Exercise real AVFoundation: a valid system CAF and broken microphone container.
    let native = root.appending(path: "native")
    try fm.createDirectory(at: native, withIntermediateDirectories: true)
    let format = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000)!
    buffer.frameLength = 24_000
    for index in 0..<24_000 { buffer.floatChannelData![0][index] = 0 }
    do {
        let file = try AVAudioFile(forWriting: native.appending(path: "system-audio.caf"), settings: format.settings)
        try file.write(from: buffer)
    }
    let brokenMicrophone = Data("incomplete microphone container".utf8)
    try brokenMicrophone.write(to: native.appending(path: "microphone.m4a"))
    let partial = try await CapturePreparation.prepare(in: native)
    precondition(partial.state == .ready && partial.mode == .systemAudioOnly)
    let playableDuration = try await AVURLAsset(url: native.appending(path: "capture.mov")).load(.duration).seconds
    precondition(playableDuration > 0.9)
    let retained = try Data(contentsOf: native.appending(path: "microphone.m4a"))
    precondition(retained == brokenMicrophone && partial.warning != nil)
    let reloaded = try CapturePreparation.load(in: native)
    precondition(reloaded == partial, "Partial recovery must survive restart")
    _ = try await CapturePreparation.prepare(in: native) { _, _, _ in
        preconditionFailure("Ready receipt must reuse its complete output")
    }

    // In-person meeting: the computer played nothing, so the system track is valid but empty.
    // A receipt left by the old system-only fallback must not block microphone recovery.
    let inPerson = root.appending(path: "in-person")
    try fm.createDirectory(at: inPerson, withIntermediateDirectories: true)
    _ = try AVAudioFile(forWriting: inPerson.appending(path: "system-audio.caf"), settings: format.settings)
    do {
        let file = try AVAudioFile(forWriting: inPerson.appending(path: "microphone.m4a"), settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000, AVNumberOfChannelsKey: 1
        ])
        try file.write(from: buffer)
    }
    try CapturePreparation(state: .preparing, mode: .systemAudioOnly, reason: "The recording contains no audio.")
        .write(in: inPerson)
    let microphoneOnly = try await CapturePreparation.prepare(in: inPerson)
    precondition(microphoneOnly.state == .ready && microphoneOnly.mode == .microphoneOnly && microphoneOnly.warning == nil)
    let inPersonDuration = try await AVURLAsset(url: inPerson.appending(path: "capture.mov")).load(.duration).seconds
    precondition(inPersonDuration > 0.9)

    // Crash after publishing fallback but before ready: next attempt must rebuild, not trust that movie.
    let interrupted = root.appending(path: "interrupted")
    try fm.createDirectory(at: interrupted, withIntermediateDirectories: true)
    for name in ["system-audio.caf", "microphone.m4a", "capture.mov", "audio.m4a", "coverage.json"] {
        try Data("old \(name)".utf8).write(to: interrupted.appending(path: name))
    }
    var attempts = 0
    do {
        _ = try await CapturePreparation.prepare(in: interrupted) { _, microphone, output in
            attempts += 1
            let receipt = try CapturePreparation.load(in: interrupted)!
            precondition(receipt.state == .preparing, "Receipt must precede every publication")
            if microphone != nil {
                precondition(receipt.mode == .complete)
                throw InjectedFailure.mix
            }
            precondition(receipt.mode == .systemAudioOnly)
            try Data("fallback movie".utf8).write(to: output)
            throw InjectedFailure.crash
        }
        preconditionFailure("Interrupted fallback accepted")
    } catch InjectedFailure.crash {}
    precondition(attempts == 2)
    let incomplete = try CapturePreparation.load(in: interrupted)!
    precondition(incomplete.state == .preparing && incomplete.retainsRawTracks)
    precondition(!fm.fileExists(atPath: interrupted.appending(path: "audio.m4a").path))
    precondition(!fm.fileExists(atPath: interrupted.appending(path: "coverage.json").path))
    var rebuilt = false
    let recovered = try await CapturePreparation.prepare(in: interrupted) { _, microphone, output in
        precondition(microphone == nil, "Retry must preserve the durable recovery mode")
        rebuilt = true
        try Data("rebuilt movie".utf8).write(to: output)
    }
    precondition(rebuilt && recovered.state == .ready && recovered.retainsRawTracks)
    precondition(fm.fileExists(atPath: interrupted.appending(path: "microphone.m4a").path))

    // An unreadable/corrupt receipt must not masquerade as an old session with no record.
    try Data("broken receipt".utf8).write(to: interrupted.appending(path: CapturePreparation.fileName))
    do {
        _ = try await CapturePreparation.prepare(in: interrupted) { _, _, _ in
            preconditionFailure("Corrupt receipt must fail before mixing")
        }
        preconditionFailure("Corrupt receipt accepted")
    } catch is DecodingError {}

    // Failure to persist the preparation plan must occur before any export.
    let unwritable = root.appending(path: "unwritable")
    try fm.createDirectory(at: unwritable, withIntermediateDirectories: true)
    try Data("raw".utf8).write(to: unwritable.appending(path: "system-audio.caf"))
    try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: unwritable.path)
    defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritable.path) }
    do {
        _ = try await CapturePreparation.prepare(in: unwritable) { _, _, _ in
            preconditionFailure("Export began before its plan was safely persisted")
        }
        preconditionFailure("Unwritable receipt accepted")
    } catch {}
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: unwritable.path)
    print("Capture preparation passed: native partial recovery, durable receipt, crash retry, cache invalidation and fail-closed writes")
}
