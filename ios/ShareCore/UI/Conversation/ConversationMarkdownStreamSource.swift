import Foundation
import SwiftStreamingMarkdown

public final class ConversationMarkdownStreamSource: StreamedMarkdownSource, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<String>.Continuation] = [:]
    private var latestText = ""
    private var isFinished = false

    public init() {}

    public var text: AsyncStream<String> {
        let id = UUID()
        return AsyncStream<String>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let state = lock.withLock { () -> (String, Bool) in
                if !isFinished {
                    continuations[id] = continuation
                }
                return (latestText, isFinished)
            }

            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }

            if !state.0.isEmpty {
                continuation.yield(state.0)
            }
            if state.1 {
                continuation.finish()
            }
        }
    }

    public func reset() {
        let continuations = lock.withLock { () -> [AsyncStream<String>.Continuation] in
            let active = Array(self.continuations.values)
            self.continuations.removeAll()
            latestText = ""
            isFinished = false
            return active
        }
        continuations.forEach { $0.finish() }
    }

    public func yield(_ text: String) {
        let continuations = lock.withLock { () -> [AsyncStream<String>.Continuation] in
            guard !isFinished else { return [] }
            latestText = text
            return Array(self.continuations.values)
        }
        continuations.forEach { $0.yield(text) }
    }

    public func finish() {
        let continuations = lock.withLock { () -> [AsyncStream<String>.Continuation] in
            guard !isFinished else { return [] }
            isFinished = true
            let active = Array(self.continuations.values)
            self.continuations.removeAll()
            return active
        }
        continuations.forEach { $0.finish() }
    }

    private func removeContinuation(id: UUID) {
        lock.withLock {
            continuations[id] = nil
        }
    }
}
