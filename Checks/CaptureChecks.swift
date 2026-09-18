// Appended to SystemAudioCapture.swift and CaptureService.swift by check.sh.
// Exercise callback state with an injected private writer; never start a device.
private final class CaptureWriteProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var writes = 0
    private var failures: [String] = []
    private var levels: [Float] = []

    func wrote() { lock.withLock { writes += 1 } }
    func failed(_ message: String) { lock.withLock { failures.append(message) } }
    func level(_ value: Float) { lock.withLock { levels.append(value) } }
    func snapshot() -> (writes: Int, failures: [String], levels: [Float]) {
        lock.withLock { (writes, failures, levels) }
    }
}

extension SystemAudioCapture {
    static func checkWriteFailure() throws {
        let capture = SystemAudioCapture()
        let probe = CaptureWriteProbe()
        capture.onLevel = { _, value in probe.level(value) }
        capture.onWriteFailure = { _, message in probe.failed(message) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
        buffer.frameLength = 8
        for frame in 0..<8 { buffer.floatChannelData![0][frame] = 0.5 }

        let generation = UUID()
        capture.prepareOutput(generation: generation)
        capture.queue.sync {
            capture.output.process(buffer, generation: generation) { probe.wrote() }
            capture.output.process(buffer, generation: generation) {
                probe.wrote()
                throw CocoaError(.fileWriteOutOfSpace)
            }
            for _ in 0..<3 {
                capture.output.process(buffer, generation: generation) {
                    probe.wrote()
                    throw CocoaError(.fileWriteNoPermission)
                }
            }
        }
        let failed = probe.snapshot()
        precondition(failed.writes == 2, "Stop writing after the first write error")
        precondition(failed.failures.count == 1, "Publish one immediate write error")
        precondition(failed.levels.count == 2 && failed.levels[0] > 0 && failed.levels[1] == 0,
                     "The failing callback clears the meter; later callbacks cannot publish positive levels")
        do {
            try capture.stop()
            preconditionFailure("Stop must retain and throw the first write failure")
        } catch let error as CocoaError {
            precondition(error.code == .fileWriteOutOfSpace)
        }
        try capture.stop()

        let nextGeneration = UUID()
        capture.prepareOutput(generation: nextGeneration)
        capture.queue.sync {
            capture.output.process(buffer, generation: generation) {
                preconditionFailure("A queued callback from the old capture reached the writer")
            }
            capture.output.process(buffer, generation: nextGeneration) { probe.wrote() }
        }
        let resumed = probe.snapshot()
        precondition(resumed.writes == 3 && resumed.failures.count == 1)
        precondition(resumed.levels.last! > 0, "A new capture resets both the error and level gate")
        try capture.stop()
        print("System audio passed: one immediate failure, stopped meter, retained stop error, stale callback and restart")
    }
}

extension CaptureService {
    @MainActor static func checkWriteFailureDelivery() async {
        let service = CaptureService()
        var messages: [String] = []
        var levels: [Float] = []
        service.onSystemAudioLevel = { levels.append($0) }
        let generation = service.beginSystemAudioCallbacks()

        // Use the actual cross-queue callback to verify the MainActor forwarding path.
        await withCheckedContinuation { continuation in
            service.onError = { message in
                messages.append(message)
                continuation.resume()
            }
            service.systemAudio.onWriteFailure?(generation, "Disk full")
        }
        service.onError = { messages.append($0) }
        precondition(messages == ["Disk full"] && levels == [0])
        service.receiveSystemAudioFailure("Duplicate", generation: generation)
        service.receiveSystemAudioLevel(0.8, generation: generation)
        precondition(messages == ["Disk full"] && levels == [0])

        service.invalidateSystemAudioCallbacks()
        service.receiveSystemAudioFailure("Late after stop", generation: generation)
        service.receiveSystemAudioLevel(0.9, generation: generation)
        precondition(messages == ["Disk full"] && levels == [0, 0])

        let nextGeneration = service.beginSystemAudioCallbacks()
        service.receiveSystemAudioFailure("Old capture", generation: generation)
        service.receiveSystemAudioLevel(0.9, generation: generation)
        service.receiveSystemAudioLevel(0.4, generation: nextGeneration)
        precondition(messages == ["Disk full"] && levels == [0, 0, 0.4])
        service.receiveSystemAudioFailure("Next capture", generation: nextGeneration)
        precondition(messages == ["Disk full", "Next capture"] && levels.last == 0)
        service.invalidateSystemAudioCallbacks()
        print("Capture service passed: MainActor delivery, one failure, stale errors and stale meters ignored")
    }
}
