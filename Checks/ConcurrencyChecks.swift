import Foundation

@MainActor
func checkConcurrentTranscription() async throws {
    let blocks = (0..<7).map { TranscriptBlock(id: $0, startSeconds: Double($0 * 300), endSeconds: Double(($0 + 1) * 300)) }
    let probe = BatchProbe()
    var snapshots: [[TranscriptBlock]] = []
    let result = try await TranscriptionBatch.run(blocks: blocks) { index in
        try await probe.transcribe(index)
    } checkpoint: { snapshots.append($0) } progress: { _, _ in }
    let stats = await probe.stats()
    precondition(stats.peak == 3 && stats.active == 0)
    precondition(stats.finished.first != 0, "Responses must finish out of order in this fixture")
    precondition(result.map(\.text) == (0..<7).map { "Block \($0)" })
    precondition(snapshots.count == 8, "Checkpoint every result, plus initial coverage")
    precondition(snapshots[1].filter { $0.status == .complete }.count == 1)

    let failing = BatchProbe(failFirst: true)
    var saved = blocks
    do {
        _ = try await TranscriptionBatch.run(blocks: blocks) { try await failing.transcribe($0) }
            checkpoint: { saved = $0 } progress: { _, _ in }
        preconditionFailure("Expected an authentication failure")
    } catch ProviderError.authentication {}
    let failedStats = await failing.stats()
    precondition(failedStats.started.sorted() == [0, 1, 2], "Do not start more blocks after failure")
    precondition(saved[0].status == .failed && saved[1].status == .complete && saved[2].status == .complete)
    precondition(saved[3...].allSatisfy { $0.status == .pending })
    let resumed = BatchProbe()
    let recovered = try await TranscriptionBatch.run(blocks: saved) { try await resumed.transcribe($0) }
        checkpoint: { saved = $0 } progress: { _, _ in }
    let resumedStats = await resumed.stats()
    precondition(resumedStats.started.sorted() == [0, 3, 4, 5, 6])
    precondition(recovered.allSatisfy { $0.status == .complete })

    let cancellationProbe = BatchProbe(slow: true)
    let task = Task { @MainActor in
        try await TranscriptionBatch.run(blocks: blocks) { try await cancellationProbe.transcribe($0) }
            checkpoint: { _ in } progress: { _, _ in }
    }
    while await cancellationProbe.stats().started.count < 3 { await Task.yield() }
    task.cancel()
    do { _ = try await task.value; preconditionFailure("Expected cancellation") } catch is CancellationError {}
    let cancelledStats = await cancellationProbe.stats()
    precondition(cancelledStats.started.count == 3 && cancelledStats.active == 0)

    let retries = RetryProbe()
    let text = try await ProviderRetry.run(sleep: { await retries.slept($0) }) {
        try await retries.request()
    }
    let retryStats = await retries.stats()
    precondition(text == "Success" && retryStats.attempts == 3 && retryStats.delays == [7, 4])
    precondition(ProviderRetry.delay(for: ProviderError.authentication, attempt: 0) == nil)
    precondition(ProviderRetry.delay(for: URLError(.cancelled), attempt: 0) == nil)
    precondition(ProviderRetry.delay(for: ProviderError.http(status: 400, message: "Bad request", retryAfter: nil), attempt: 0) == nil)
    precondition(ProviderRetry.delay(for: URLError(.timedOut), attempt: 0) == 2)
    precondition(ProviderRetry.retryAfter("7") == 7)
    precondition(ProviderRetry.retryAfter("Thu, 01 Jan 1970 00:00:07 GMT", now: Date(timeIntervalSince1970: 0)) == 7)
    print("Concurrent transcription passed: limit 3, ordered output, checkpoints, failure recovery, cancellation and backoff")
}

private actor BatchProbe {
    let failFirst: Bool
    let slow: Bool
    var active = 0
    var peak = 0
    var started: [Int] = []
    var finished: [Int] = []
    init(failFirst: Bool = false, slow: Bool = false) { self.failFirst = failFirst; self.slow = slow }
    func transcribe(_ index: Int) async throws -> String {
        active += 1
        peak = max(peak, active)
        started.append(index)
        defer { active -= 1 }
        let milliseconds = slow ? 10_000 : (failFirst ? (index == 0 ? 10 : 150) : (index == 0 ? 180 : 30))
        try await Task.sleep(for: .milliseconds(milliseconds))
        if failFirst && index == 0 { throw ProviderError.authentication }
        finished.append(index)
        return "Block \(index)"
    }
    func stats() -> (peak: Int, active: Int, started: [Int], finished: [Int]) { (peak, active, started, finished) }
}

private actor RetryProbe {
    var attempts = 0
    var delays: [TimeInterval] = []
    func request() throws -> String {
        attempts += 1
        if attempts == 1 { throw ProviderError.http(status: 429, message: "Rate limit", retryAfter: 7) }
        if attempts == 2 { throw ProviderError.http(status: 503, message: "Unavailable", retryAfter: nil) }
        return "Success"
    }
    func slept(_ seconds: TimeInterval) { delays.append(seconds) }
    func stats() -> (attempts: Int, delays: [TimeInterval]) { (attempts, delays) }
}
