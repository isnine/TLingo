import Foundation

/// Runs realtime translation requests for one lane: finals are processed in order, partials are
/// latest-wins and throttled by request start. Owners react through `handlers`; the scheduler owns
/// no presentation state.
@MainActor
final class RealtimeTranslationScheduler {
    struct Handlers {
        var translate: (RealtimeTextTranslationRequest) async throws -> ModelExecutionResult
        var finalResult: (RealtimeTextTranslationRequest, ModelExecutionResult) -> Void
        var finalFailure: (RealtimeTextTranslationRequest, Error) -> Void
        var finalCancelled: (RealtimeTextTranslationRequest) -> Void = { _ in }
        var partialResult: (RealtimeTextTranslationRequest, ModelExecutionResult) -> Void
        var partialFailure: (RealtimeTextTranslationRequest, Error) -> Void
        /// Called after the corresponding loop drained its work and cleared its task.
        var finalIdle: () -> Void = {}
        var partialIdle: () -> Void = {}
        /// While true both loops stop without draining their queues.
        var isDisabled: () -> Bool = { false }
        var now: () -> Date = Date.init
    }

    var handlers: Handlers?

    private(set) var finalTask: Task<Void, Never>?
    private(set) var partialTask: Task<Void, Never>?
    private(set) var queuedFinal: [RealtimeTextTranslationRequest] = []
    private(set) var latestPartial: RealtimeTextTranslationRequest?
    private var nextPartialAllowedAt: Date?

    var isTranslating: Bool { finalTask != nil || partialTask != nil }
    var hasWork: Bool { isTranslating || !queuedFinal.isEmpty || latestPartial != nil }

    func enqueueFinal(_ requests: [RealtimeTextTranslationRequest]) {
        queuedFinal.append(contentsOf: requests)
        startFinalIfNeeded()
    }

    func submitPartial(_ request: RealtimeTextTranslationRequest) {
        latestPartial = request
        guard partialTask == nil else { return }
        partialTask = Task { [weak self] in await self?.processPartials() }
    }

    func cancelPartial() {
        partialTask?.cancel()
        partialTask = nil
        latestPartial = nil
        nextPartialAllowedAt = nil
    }

    func cancelAll() {
        finalTask?.cancel()
        finalTask = nil
        queuedFinal.removeAll()
        cancelPartial()
    }

    /// Drops queued work without cancelling the running request (used once translation is disabled).
    func dropPending() {
        queuedFinal.removeAll()
        latestPartial = nil
    }

    /// Cancels the partial loop and waits for both loops to finish their current request.
    func settle() async {
        let partial = partialTask
        cancelPartial()
        await partial?.value
        await finalTask?.value
    }

    private func startFinalIfNeeded() {
        guard finalTask == nil, !queuedFinal.isEmpty else { return }
        finalTask = Task { [weak self] in await self?.processFinals() }
    }

    private func processFinals() async {
        while !Task.isCancelled {
            guard let handlers else { return }
            guard !handlers.isDisabled(), !queuedFinal.isEmpty else {
                let disabled = handlers.isDisabled()
                finalTask = nil
                if !disabled { handlers.finalIdle() }
                return
            }
            let request = queuedFinal.removeFirst()
            do {
                guard !Task.isCancelled else { return }
                let result = try await handlers.translate(request)
                guard !Task.isCancelled else { return }
                handlers.finalResult(request, result)
                if !queuedFinal.isEmpty, request.cadenceInterval > 0 {
                    try await Task.sleep(for: .milliseconds(Int((request.cadenceInterval * 1000).rounded(.up))))
                }
            } catch is CancellationError {
                // The canceller already cleared the handle and may have scheduled a replacement.
                handlers.finalCancelled(request)
                return
            } catch {
                handlers.finalFailure(request, error)
            }
        }
    }

    private func processPartials() async {
        while !Task.isCancelled {
            guard let handlers else { return }
            guard !handlers.isDisabled(), var request = latestPartial else {
                let disabled = handlers.isDisabled()
                partialTask = nil
                if !disabled {
                    nextPartialAllowedAt = nil
                    handlers.partialIdle()
                }
                return
            }
            latestPartial = nil
            do {
                // Throttle by request start, so a slow translation is followed immediately by the next one.
                let allowedAt = nextPartialAllowedAt ?? handlers.now().addingTimeInterval(request.cadenceInterval)
                nextPartialAllowedAt = allowedAt
                let delay = allowedAt.timeIntervalSince(handlers.now())
                if delay > 0 {
                    try await Task.sleep(for: .milliseconds(Int((delay * 1000).rounded(.up))))
                }
                if let newer = latestPartial {
                    request = newer
                    latestPartial = nil
                }
                guard !Task.isCancelled else { return }
                nextPartialAllowedAt = handlers.now().addingTimeInterval(request.cadenceInterval)
                let result = try await handlers.translate(request)
                guard !Task.isCancelled else { return }
                handlers.partialResult(request, result)
            } catch is CancellationError {
                return
            } catch {
                handlers.partialFailure(request, error)
            }
        }
    }
}
