import Foundation

final class StreamingUpdateCoalescer: @unchecked Sendable {
    private let interval: Duration
    private let publish: @Sendable (StreamingUpdate) -> Void
    private let lock = NSLock()
    private var lastPublishedAt: ContinuousClock.Instant?
    private var pending: StreamingUpdate?
    private var task: Task<Void, Never>?
    private var isCancelled = false

    init(interval: Duration = .milliseconds(66), publish: @escaping @Sendable (StreamingUpdate) -> Void) {
        self.interval = interval
        self.publish = publish
    }

    func append(_ update: StreamingUpdate) {
        switch update {
        case let .text(text) where text.isEmpty: return
        case let .sentencePairs(pairs) where pairs.isEmpty: return
        default: break
        }

        enum Action {
            case none
            case publishNow(StreamingUpdate)
            case schedule(ContinuousClock.Instant)
        }

        let action: Action = lock.withLock {
            guard !isCancelled else { return .none }
            pending = update
            guard let lastPublishedAt else {
                self.pending = nil
                self.lastPublishedAt = .now
                return .publishNow(update)
            }
            let deadline = lastPublishedAt.advanced(by: interval)
            if ContinuousClock.now >= deadline {
                task?.cancel()
                task = nil
                self.pending = nil
                self.lastPublishedAt = .now
                return .publishNow(update)
            }
            if task == nil {
                return .schedule(deadline)
            }
            return .none
        }

        switch action {
        case .none:
            break
        case let .publishNow(value):
            publish(value)
        case let .schedule(deadline):
            let scheduledTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try await ContinuousClock().sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.flush()
            }
            lock.withLock {
                if isCancelled || pending == nil {
                    scheduledTask.cancel()
                } else if task == nil {
                    task = scheduledTask
                } else {
                    scheduledTask.cancel()
                }
            }
        }
    }

    func flush() {
        let update: StreamingUpdate? = lock.withLock {
            task?.cancel()
            task = nil
            guard !isCancelled, let update = pending else { return nil }
            pending = nil
            lastPublishedAt = .now
            return update
        }
        if let update {
            publish(update)
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            task?.cancel()
            task = nil
            pending = nil
        }
    }
}
