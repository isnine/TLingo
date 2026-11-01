#if os(iOS)
    import ActivityKit
    import Combine
    import Foundation
    import os
    import ShareCore

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "RealtimeLiveActivity")

    /// Mirrors the running realtime session into a Live Activity on the Lock Screen and Dynamic Island.
    @MainActor
    final class RealtimeLiveActivityController: ObservableObject {
        /// ActivityKit throttles frequent updates; one per second keeps captions current within budget.
        private static let updateInterval: RunLoop.SchedulerTimeType.Stride = .seconds(1)
        private static let captionCharacterLimit = 160

        private let store: RealtimeSessionStore
        private let preferences: AppPreferences
        private var activity: Activity<RealtimeActivityAttributes>?
        private var activityStateTask: Task<Void, Never>?
        private var cancellables: Set<AnyCancellable> = []

        init(store: RealtimeSessionStore, preferences: AppPreferences = .shared) {
            self.store = store
            self.preferences = preferences
            Self.endUntrackedActivities()

            store.$isRunning
                .removeDuplicates()
                .receive(on: RunLoop.main)
                .sink { [weak self] isRunning in
                    if isRunning {
                        self?.start()
                    } else {
                        self?.end()
                    }
                }
                .store(in: &cancellables)

            store.$captionLines
                .combineLatest(store.$isPaused)
                .throttle(for: Self.updateInterval, scheduler: RunLoop.main, latest: true)
                .sink { [weak self] lines, isPaused in
                    self?.update(state: Self.contentState(lines: lines, isPaused: isPaused))
                }
                .store(in: &cancellables)
        }

        private func start() {
            guard activity == nil, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            Self.endUntrackedActivities()
            let attributes = RealtimeActivityAttributes(languagePair: languagePair)
            let state = Self.contentState(lines: store.captionLines, isPaused: store.isPaused)
            do {
                let activity = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: state, staleDate: nil)
                )
                self.activity = activity
                observeEnd(of: activity)
            } catch {
                logger.error("Live Activity request failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        private func update(state: RealtimeActivityAttributes.ContentState) {
            guard let activity, store.isRunning else { return }
            Task {
                await activity.update(ActivityContent(state: state, staleDate: nil))
            }
        }

        /// The system ends an activity after eight hours, and people can dismiss it; stop updating it then.
        /// A replacement can only be requested from the foreground, so a long session continues without one.
        private func observeEnd(of activity: Activity<RealtimeActivityAttributes>) {
            activityStateTask?.cancel()
            activityStateTask = Task { [weak self] in
                for await state in activity.activityStateUpdates where state == .ended || state == .dismissed {
                    guard let self, self.activity?.id == activity.id else { return }
                    logger.info("Live Activity ended by the system or user")
                    self.activity = nil
                    return
                }
            }
        }

        private func end() {
            activityStateTask?.cancel()
            activityStateTask = nil
            guard let activity else { return }
            self.activity = nil
            let finalState = Self.contentState(lines: store.captionLines, isPaused: true)
            Task {
                await activity.end(ActivityContent(state: finalState, staleDate: nil), dismissalPolicy: .immediate)
            }
        }

        /// Activities outlive the process, so one left by a terminated session would
        /// stay on the Lock Screen next to the new one.
        private static func endUntrackedActivities() {
            for orphan in Activity<RealtimeActivityAttributes>.activities {
                Task {
                    await orphan.end(nil, dismissalPolicy: .immediate)
                }
            }
        }

        private var languagePair: String {
            let source = preferences.realtimeSourceLanguage.primaryLabel
            guard preferences.realtimeTranslationProvider != .transcriptionOnly else { return source }
            return "\(source) → \(preferences.realtimeTargetLanguage.primaryLabel)"
        }

        static func contentState(lines: [RealtimeCaptionLine], isPaused: Bool) -> RealtimeActivityAttributes.ContentState {
            func latest(_ kind: RealtimeCaptionLine.Kind) -> String {
                let text = lines.last { $0.kind == kind && !$0.text.isEmpty }?.text ?? ""
                // Keep the tail: the newest words matter most and the payload must stay small.
                return text.count > captionCharacterLimit ? "…" + text.suffix(captionCharacterLimit) : text
            }
            return RealtimeActivityAttributes.ContentState(
                translation: latest(.translation),
                source: latest(.source),
                isPaused: isPaused
            )
        }
    }
#endif
