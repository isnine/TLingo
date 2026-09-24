#if os(macOS)
    import Foundation
    import ShareCore

    enum MacSnapshotScene: String {
        case multiModel = "multi-model"
        case offline
        case realtimeMultiLane = "realtime-multi-lane"
        case conversation
        case polish
        case historyChat = "history-chat"

        static func current(
            arguments: [String] = ProcessInfo.processInfo.arguments
        ) -> MacSnapshotScene? {
            guard let value = SnapshotLaunchArguments.value(after: "-SNAPSHOT_SCENE", in: arguments) else {
                return nil
            }
            return MacSnapshotScene(rawValue: value)
        }

        var initialTab: RootTabView.TabItem {
            self == .realtimeMultiLane ? .realtime : .home
        }

        var showsSidebar: Bool {
            self == .multiModel || self == .historyChat
        }
    }

    @MainActor
    enum MacSnapshotData {
        static func historyRecord(localeID: String? = nil) -> TranslationRecord {
            let fixture = SnapshotLocaleCatalog.macScenes(for: localeID).history
            let record = TranslationRecord(
                sourceText: fixture.sourceText,
                actionName: fixture.actionName,
                targetLanguage: fixture.targetLanguage,
                timestamp: Date(timeIntervalSince1970: 1_783_843_200),
                modelResults: [
                    ModelResult(
                        modelID: fixture.modelID,
                        modelDisplayName: fixture.modelDisplayName,
                        resultText: fixture.resultText,
                        duration: 1.4
                    ),
                ]
            )
            record.historyAnnotations = [record.id.uuidString: fixture.annotation]
            return record
        }

        static func historyRecords(localeID: String? = nil) -> [TranslationRecord] {
            let scenes = SnapshotLocaleCatalog.macScenes(for: localeID)
            let featured = historyRecord(localeID: localeID)
            let sidebarRecords = scenes.history.sidebarRecords.enumerated().map { index, fixture in
                let timestamp = Date(timeIntervalSince1970: 1_783_842_600 - Double(index * 900))
                if fixture.kind == "realtime" {
                    return makeRealtimeRecord(fixture: fixture, timestamp: timestamp)
                }
                return makeTextRecord(fixture: fixture, timestamp: timestamp)
            }
            return [featured] + sidebarRecords
        }

        static func historyChatMessages(localeID: String? = nil) -> [ChatMessage] {
            SnapshotLocaleCatalog.macScenes(for: localeID).history.chatMessages.map {
                ChatMessage(role: $0.role, content: $0.content)
            }
        }

        private static func makeTextRecord(
            fixture: SnapshotMacHistoryRecordFixture,
            timestamp: Date
        ) -> TranslationRecord {
            TranslationRecord(
                sourceText: fixture.sourceText,
                actionName: fixture.actionName,
                targetLanguage: fixture.targetLanguage,
                timestamp: timestamp,
                modelResults: [
                    ModelResult(
                        modelID: fixture.modelID,
                        modelDisplayName: fixture.modelDisplayName,
                        resultText: fixture.resultText,
                        duration: 1.4
                    ),
                ]
            )
        }

        private static func makeRealtimeRecord(
            fixture: SnapshotMacHistoryRecordFixture,
            timestamp: Date
        ) -> TranslationRecord {
            let requestID = UUID()
            let segment = RealtimeHistorySegment(
                offset: 12,
                sourceText: fixture.sourceText,
                translatedText: fixture.resultText
            )
            let record = TranslationRecord(
                requestID: requestID,
                sourceText: fixture.sourceText,
                actionName: TranslationRecord.realtimeActionName,
                targetLanguage: fixture.targetLanguage,
                timestamp: timestamp,
                modelResults: [
                    ModelResult(
                        modelID: fixture.modelID,
                        modelDisplayName: fixture.modelDisplayName,
                        resultText: fixture.resultText,
                        duration: 18
                    ),
                ]
            )
            record.realtimeSession = RealtimeHistorySession(
                requestID: requestID,
                generatedTitle: fixture.sourceText,
                startedAt: timestamp.addingTimeInterval(-18),
                endedAt: timestamp,
                duration: 18,
                inputSource: RealtimeHistoryAudioSource.macAudio.title,
                inputSourceID: .macAudio,
                sourceLanguage: "English",
                targetLanguage: fixture.targetLanguage,
                modelID: fixture.modelID,
                modelDisplayName: fixture.modelDisplayName,
                segments: [segment]
            )
            return record
        }
    }
#endif
