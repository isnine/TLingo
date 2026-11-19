#if DEBUG && os(iOS)
    import Foundation
    import os
    import SwiftUI
    import UIKit

    /// Opt-in simulator benchmark using the production view model and result card.
    public struct TextTranslationBenchmarkView: View {
        @StateObject private var viewModel: HomeViewModel
        private let preferences: AppPreferences
        @State private var progress = "Preparing model catalog"
        @State private var started = false
        @State private var records: [Record] = []

        public init() {
            let suite = "com.zanderwang.text-benchmark.\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else {
                preconditionFailure("Cannot create isolated benchmark preferences")
            }
            let preferences = AppPreferences(defaults: defaults)
            preferences.setSourceLanguage(.english)
            preferences.setTargetLanguage(.simplifiedChinese)
            preferences.setWordLookupEnabled(false)
            preferences.setDefaultsToSentencePairs(false)
            self.preferences = preferences
            _viewModel = StateObject(wrappedValue: HomeViewModel(preferences: preferences))
        }

        public var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Text translation benchmark").font(.headline)
                    Text(progress).font(.caption).accessibilityIdentifier("benchmark_progress")
                    Text(viewModel.inputText).font(.callout)
                    ForEach(viewModel.modelRuns) { run in
                        ProviderResultCardView(
                            run: run, showModelName: true, viewModel: viewModel, onCopy: { _ in }
                        )
                        .background(TranslationFrameProbe(run: run))
                    }
                }
                .padding()
            }
            .task {
                guard !started else { return }
                started = true
                do {
                    try await benchmark()
                } catch {
                    progress = "Benchmark failed: \(error.localizedDescription)"
                    Logger(subsystem: "com.zanderwang.AITranslator", category: "TextBenchmark")
                        .error("\(progress, privacy: .public)")
                }
            }
        }

        private func benchmark() async throws {
            guard let directory = ProcessInfo.processInfo.environment["TLINGO_TEXT_BENCHMARK_OUTPUT"] else {
                throw BenchmarkError.missingOutput
            }
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let catalog = try await ModelsService.shared.fetchModels(forceRefresh: true)
            let matrix = catalog + [.microsoftTranslate, .appleTranslate] + ModelConfig.appleIntelligenceModels
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(matrix).write(to: output.appendingPathComponent("models.json"), options: .atomic)
            try encoder.encode(Self.inputs).write(to: output.appendingPathComponent("inputs.json"), options: .atomic)
            while viewModel.isLoadingModels {
                try await Task.sleep(for: .milliseconds(50))
            }
            await Entitlement.shared.refresh()
            let repeats = Int(ProcessInfo.processInfo.environment["TLINGO_TEXT_BENCHMARK_REPEATS"] ?? "3") ?? 3
            guard (1 ... 10).contains(repeats) else { throw BenchmarkError.invalidRepeats }
            let selectedIDs = ProcessInfo.processInfo.environment["TLINGO_TEXT_BENCHMARK_MODELS"]
                .map { Set($0.split(separator: ",").map(String.init)) }
            let actionIDs = (ProcessInfo.processInfo.environment["TLINGO_TEXT_BENCHMARK_ACTIONS"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let resolvedActionIDs = actionIDs.isEmpty ? [BuiltInActionCatalog.translateActionID] : actionIDs
            for actionID in resolvedActionIDs {
                for model in matrix where selectedIDs?.contains(model.id) ?? true {
                    for inputIndex in Self.inputs.indices {
                        for repetition in 1 ... (inputIndex == 0 ? repeats : 1) {
                            try await records.append(
                                measure(actionID: actionID, model: model, inputIndex: inputIndex, repetition: repetition)
                            )
                            try encoder.encode(records).write(
                                to: output.appendingPathComponent("results.json"),
                                options: .atomic
                            )
                            try await Task.sleep(for: .milliseconds(300))
                        }
                    }
                }
            }
            progress = "Complete: \(records.count) measurements"
            try Data(progress.utf8).write(to: output.appendingPathComponent("complete.txt"), options: .atomic)
        }

        private func measure(actionID: String, model: ModelConfig, inputIndex: Int, repetition: Int) async throws -> Record {
            progress = "[\(actionID)] \(model.displayName) / input \(inputIndex + 1) / run \(repetition)"
            preferences.setEnabledModelIDs([model.id])
            preferences.setDefaultsToSentencePairs(actionID == BuiltInActionCatalog.sentenceTranslateActionID)
            let effectiveActionID = actionID == BuiltInActionCatalog.sentenceTranslateActionID
                ? BuiltInActionCatalog.translateActionID
                : actionID
            viewModel.selectedActionID = effectiveActionID
            viewModel.inputText = ""
            viewModel.inputText = Self.inputs[inputIndex]
            viewModel.performSelectedAction()
            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            while viewModel.modelRuns.isEmpty || viewModel.modelRuns.contains(where: \.isRunning),
                  ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(50))
            }
            let timedOut = viewModel.modelRuns.first { $0.id == model.id }?.isRunning == true
            // Allow the final native frame probe to observe the applied result.
            try await Task.sleep(for: .milliseconds(200))
            let run = viewModel.modelRuns.first { $0.id == model.id }
            var record = Record(
                actionID: actionID,
                modelID: model.id, inputIndex: inputIndex, repetition: repetition,
                status: "unavailable", timing: run?.timingTrace?.snapshot()
            )
            switch run?.status {
            case _ where timedOut:
                record.status = "failure"
                record.error = "Benchmark deadline exceeded for \(model.id)"
                viewModel.inputText = ""
            case let .success(value):
                record.status = "success"
                record.output = value.copyText
            case let .failure(message, _, _, _):
                record.status = "failure"
                record.error = message
            default:
                record.error = "Model unavailable in this simulator or entitlement"
            }
            return record
        }

        private struct Record: Codable {
            let actionID: String
            let modelID: String
            let inputIndex: Int
            let repetition: Int
            var status: String
            var output: String?
            var error: String?
            let timing: TranslationTimingTrace.Snapshot?
        }

        private enum BenchmarkError: LocalizedError {
            case missingOutput, invalidRepeats
            var errorDescription: String? {
                switch self {
                case .missingOutput: "TLINGO_TEXT_BENCHMARK_OUTPUT is required"
                case .invalidRepeats: "Repeat count must be between 1 and 10"
                }
            }
        }

        private static let inputs = [
            "The meeting has been moved to Friday. Please send me the updated agenda before noon.",
            """
            We are preparing a small release for next week. The main goal is to make text translation feel immediate, \
            without changing the meaning or tone of the original message. Please keep the paragraphs and punctuation \
            intact, and avoid adding explanations.

            If the network is slow, show the first useful part of the result as soon as it arrives. When the last part \
            is available, the complete translation should be readable right away. We will compare several models \
            using the same input and language pair before deciding which changes are worth making.
            """,
        ]
    }
#endif
