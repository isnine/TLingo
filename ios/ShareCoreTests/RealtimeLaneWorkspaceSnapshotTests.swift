#if os(macOS)
    import AppKit
    import SnapshotTesting
    import SwiftUI
    import XCTest

    @testable import ShareCore

    @MainActor
    final class RealtimeLaneWorkspaceSnapshotTests: XCTestCase {
        func testOneLaneLight() throws {
            try assertWorkspaceSnapshot(
                snapshots: [Self.readySnapshot],
                primaryLaneID: Self.readySnapshot.id,
                size: CGSize(width: 680, height: 520),
                colorScheme: .light,
                name: "one-lane-light"
            )
        }

        func testOneLaneLatencyNarrow() throws {
            try assertWorkspaceSnapshot(
                snapshots: [Self.latencySnapshot],
                primaryLaneID: Self.latencySnapshot.id,
                size: CGSize(width: 352, height: 520),
                colorScheme: .light,
                name: "one-lane-latency-narrow"
            )
        }

        func testTwoLanesDark() throws {
            try assertWorkspaceSnapshot(
                snapshots: Array(Self.snapshots.prefix(2)),
                primaryLaneID: Self.snapshots[1].id,
                size: CGSize(width: 900, height: 520),
                colorScheme: .dark,
                name: "two-lanes-dark"
            )
        }

        func testThreeLanesWide() throws {
            try assertWorkspaceSnapshot(
                snapshots: Self.snapshots,
                primaryLaneID: Self.snapshots[0].id,
                size: CGSize(width: 1180, height: 520),
                colorScheme: .light,
                name: "three-lanes-wide"
            )
        }

        func testThreeLanesNarrow() throws {
            try assertWorkspaceSnapshot(
                snapshots: Self.snapshots,
                primaryLaneID: Self.snapshots[2].id,
                size: CGSize(width: 720, height: 520),
                colorScheme: .dark,
                name: "three-lanes-narrow"
            )
        }

        private func assertWorkspaceSnapshot(
            snapshots: [RealtimeLaneSnapshot],
            primaryLaneID: UUID,
            size: CGSize,
            colorScheme: ColorScheme,
            name: String,
            file: StaticString = #filePath,
            testName: String = #function,
            line: UInt = #line
        ) throws {
            let suiteName = "RealtimeLaneWorkspaceSnapshotTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let preferences = AppPreferences(defaults: defaults)
            let store = RealtimeSessionStore(preferences: preferences)
            store.applyLaneSnapshotFixture(snapshots, primaryLaneID: primaryLaneID)

            let content = RealtimeLaneWorkspace(store: store)
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, colorScheme)
            let hostingView = NSHostingView(rootView: content)
            hostingView.frame = CGRect(origin: .zero, size: size)
            hostingView.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
            hostingView.layoutSubtreeIfNeeded()

            let record: SnapshotTestingConfiguration.Record? =
                ProcessInfo.processInfo.environment["RECORD_REALTIME_LANE_SNAPSHOTS"] == "1" ? .all : nil
            withSnapshotTesting(record: record) {
                assertSnapshot(
                    of: hostingView,
                    as: .image(
                        precision: 0.99,
                        perceptualPrecision: 0.98,
                        size: size
                    ),
                    named: name,
                    timeout: 10,
                    file: file,
                    testName: testName,
                    line: line
                )
            }
        }

        private static let readySnapshot = makeSnapshot(
            modelID: RecognitionModelDescriptor.appleSpeech.id,
            provider: .appleTranslator,
            phase: .ready,
            source: "",
            translation: ""
        )

        private static let latencySnapshot = makeSnapshot(
            modelID: RecognitionModelDescriptor.appleSpeech.id,
            provider: .appleTranslator,
            phase: .translating,
            source: "The latest stable segment is ready.",
            translation: "最新的稳定片段已准备就绪。",
            latency: RealtimeLaneLatency(
                recognitionLatency: 0.42,
                translationLatency: 0.18
            )
        )

        private static let snapshots: [RealtimeLaneSnapshot] = [
            makeSnapshot(
                modelID: RecognitionModelDescriptor.appleSpeech.id,
                provider: .appleTranslator,
                phase: .recognizing,
                source: "The quarterly review starts in five minutes.",
                translation: "季度评审将在五分钟后开始。"
            ),
            makeSnapshot(
                modelID: RecognitionModelDescriptor.nemotronStreaming1120.id,
                provider: .appleTranslationRealtime,
                phase: .translating,
                source: "Please open the latest revenue forecast.",
                translation: "请打开最新的收入预测。"
            ),
            makeSnapshot(
                modelID: RecognitionModelDescriptor.parakeetEOU320.id,
                provider: .appleTranslationRealtime,
                phase: .listening,
                source: "We should compare both recognition streams.",
                translation: "我们应该比较两条识别流。",
                startedOffset: 42
            ),
        ]

        private static func makeSnapshot(
            modelID: String,
            provider: RealtimeTranslationProvider,
            phase: RealtimeLaneSnapshot.Phase,
            source: String,
            translation: String,
            startedOffset: TimeInterval = 0,
            latency: RealtimeLaneLatency? = nil
        ) -> RealtimeLaneSnapshot {
            let configuration = RealtimeLaneConfiguration(
                recognitionModelID: modelID,
                translationProvider: provider
            )
            let captionLines: [RealtimeCaptionLine] = source.isEmpty && translation.isEmpty ? [] : [
                RealtimeCaptionLine(
                    id: "\(configuration.id)-source",
                    kind: .source,
                    text: source
                ),
                RealtimeCaptionLine(
                    id: "\(configuration.id)-translation",
                    kind: .translation,
                    text: translation
                ),
            ]
            return RealtimeLaneSnapshot(
                configuration: configuration,
                phase: phase,
                sourceText: source,
                translatedText: translation,
                sentencePairs: source.isEmpty && translation.isEmpty
                    ? []
                    : [SentencePair(original: source, translation: translation)],
                captionLines: captionLines,
                startedOffset: startedOffset,
                latency: latency
            )
        }
    }
#endif
