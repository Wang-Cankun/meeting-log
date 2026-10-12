import Foundation

/// Owns result ordering and checkpoint writes; network work runs in child tasks.
@MainActor
enum TranscriptionBatch {
    nonisolated static let concurrencyLimit = 8

    static func run(
        blocks original: [TranscriptBlock],
        limit: Int = concurrencyLimit,
        transcribe: @escaping @Sendable (Int) async throws -> String,
        checkpoint: ([TranscriptBlock]) throws -> Void,
        progress: (Int, Int) -> Void
    ) async throws -> [TranscriptBlock] {
        var blocks = original
        let pending = blocks.indices.filter { blocks[$0].status != .complete || blocks[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var next = 0
        var firstError: Error?
        var complete = blocks.count - pending.count
        try checkpoint(blocks)
        progress(complete, blocks.count)

        try await withThrowingTaskGroup(of: BlockResult.self) { group in
            func submit(_ index: Int) {
                group.addTask {
                    do {
                        try Task.checkCancellation()
                        let text = try await transcribe(index).trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { throw ProviderError.invalidResponse }
                        return BlockResult(index: index, result: .success(text))
                    } catch {
                        return BlockResult(index: index, result: .failure(error))
                    }
                }
            }
            while next < min(limit, pending.count) {
                submit(pending[next])
                next += 1
            }
            while let value = try await group.next() {
                switch value.result {
                case let .success(text):
                    blocks[value.index].text = text
                    blocks[value.index].status = .complete
                    blocks[value.index].error = nil
                    complete += 1
                case let .failure(error):
                    blocks[value.index].status = .failed
                    blocks[value.index].error = error.localizedDescription
                    if firstError == nil { firstError = error }
                    if case ProviderError.authentication = error { firstError = error }
                    if case SpeechError.authentication = error { firstError = error }
                }
                try checkpoint(blocks)
                progress(complete, blocks.count)
                // Preserve other in-flight successes after a failure, but start no new work.
                if firstError == nil, !Task.isCancelled, next < pending.count {
                    submit(pending[next])
                    next += 1
                }
            }
        }
        try Task.checkCancellation()
        if let firstError { throw firstError }
        return blocks
    }

    private struct BlockResult: Sendable {
        let index: Int
        let result: Result<String, Error>
    }
}
