import Foundation

@MainActor
final class StreamingUpdateCoalescer {
    private let interval: Duration
    private let publish: (StreamingUpdate) -> Void
    private var lastPublishedAt: ContinuousClock.Instant?
    private var pending: StreamingUpdate?
    private var task: Task<Void, Never>?

    init(interval: Duration = .milliseconds(66), publish: @escaping (StreamingUpdate) -> Void) {
        self.interval = interval
        self.publish = publish
    }

    func append(_ update: StreamingUpdate) {
        switch update {
        case let .text(text) where text.isEmpty: return
        case let .sentencePairs(pairs) where pairs.isEmpty: return
        default: break
        }
        pending = update
        guard let lastPublishedAt else {
            flush()
            return
        }
        let deadline = lastPublishedAt.advanced(by: interval)
        if ContinuousClock.now >= deadline {
            flush()
        } else if task == nil {
            task = Task { [weak self] in
                do {
                    try await ContinuousClock().sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.flush()
            }
        }
    }

    func flush() {
        task?.cancel()
        task = nil
        guard let update = pending else { return }
        pending = nil
        lastPublishedAt = .now
        publish(update)
    }

    func cancel() {
        task?.cancel()
        task = nil
        pending = nil
    }
}
