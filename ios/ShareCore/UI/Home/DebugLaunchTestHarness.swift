#if DEBUG
    import Foundation
    import os
    import SwiftUI
    #if os(iOS)
        import UIKit
    #endif

    private let debugTimingLogger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "DebugTiming")

    public struct DebugLaunchTestConfig: Sendable {
        public enum ExecutionMode: String, Codable, Sendable {
            case parallel
            case serial
        }

        public enum InputPreset: String, Codable, Sendable {
            case short
            case long
            case both

            var expanded: [InputPreset] {
                switch self {
                case .short: [.short]
                case .long: [.long]
                case .both: [.short, .long]
                }
            }
        }

        public static let current: DebugLaunchTestConfig? = parse()

        public static var isEnabled: Bool {
            current != nil
        }

        public let actionIDs: [String]
        public let modelFilter: String
        public let executionMode: ExecutionMode
        public let customText: String?
        public let inputPreset: InputPreset
        public let sourceLanguageCode: String
        public let targetLanguageCode: String
        public let repeats: Int
        public let outputDirectory: URL

        private static let allActionIDs = [
            BuiltInActionCatalog.translateActionID,
            "polish",
            "grammar-check",
            "simplify",
            "sentence-analysis",
            BuiltInActionCatalog.sentenceTranslateActionID,
        ]

        private static func parse(
            arguments: [String] = ProcessInfo.processInfo.arguments,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) -> DebugLaunchTestConfig? {
            func value(flag: String, envKey: String) -> String? {
                if let index = arguments.firstIndex(of: flag), index + 1 < arguments.count {
                    return arguments[index + 1]
                }
                if let envValue = environment[envKey], !envValue.isEmpty {
                    return envValue
                }
                return nil
            }

            let rawActions = value(flag: "-TLingoDebugActions", envKey: "TLINGO_DEBUG_ACTIONS")
                ?? value(flag: "-TLingoDebugAction", envKey: "TLINGO_DEBUG_ACTION")
            guard let rawActions else { return nil }

            let parsedActions: [String]
            if rawActions.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "all" {
                parsedActions = allActionIDs
            } else {
                parsedActions = rawActions
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
            guard !parsedActions.isEmpty else { return nil }

            let modelFilter = value(flag: "-TLingoDebugModels", envKey: "TLINGO_DEBUG_MODELS") ?? "all"
            let rawMode = value(flag: "-TLingoDebugExecutionMode", envKey: "TLINGO_DEBUG_EXECUTION_MODE")?
                .lowercased()
            let executionMode: ExecutionMode = rawMode.flatMap(ExecutionMode.init(rawValue:))
                ?? (parsedActions.count == 1 ? .parallel : .serial)

            let customText = value(flag: "-TLingoDebugText", envKey: "TLINGO_DEBUG_TEXT")
            let rawPreset = value(flag: "-TLingoDebugInputPreset", envKey: "TLINGO_DEBUG_INPUT_PRESET")?.lowercased()
            let inputPreset = rawPreset.flatMap(InputPreset.init(rawValue:)) ?? .short

            let sourceLanguageCode = value(flag: "-TLingoDebugSourceLanguage", envKey: "TLINGO_DEBUG_SOURCE_LANGUAGE") ?? "en"
            let targetLanguageCode = value(flag: "-TLingoDebugTargetLanguage", envKey: "TLINGO_DEBUG_TARGET_LANGUAGE") ?? "zh-Hans"

            let rawRepeats = value(flag: "-TLingoDebugRepeats", envKey: "TLINGO_DEBUG_REPEATS")
            let repeats = max(1, min(20, Int(rawRepeats ?? "1") ?? 1))

            let defaultDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
                .appendingPathComponent("debug-pipeline-benchmark", isDirectory: true)
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("debug-pipeline-benchmark", isDirectory: true)
            let outputDirectory = value(flag: "-TLingoDebugOutput", envKey: "TLINGO_DEBUG_OUTPUT")
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? defaultDir

            return DebugLaunchTestConfig(
                actionIDs: parsedActions,
                modelFilter: modelFilter,
                executionMode: executionMode,
                customText: customText,
                inputPreset: inputPreset,
                sourceLanguageCode: sourceLanguageCode,
                targetLanguageCode: targetLanguageCode,
                repeats: repeats,
                outputDirectory: outputDirectory
            )
        }

        func inputText(for actionID: String, preset: InputPreset) -> String {
            if let customText, !customText.isEmpty {
                return customText
            }
            let isEditingAction = actionID == "polish" || actionID == "grammar-check"
            switch (isEditingAction, preset) {
            case (true, .short):
                return "We is planning to shipped the new update in Friday, and we hopes it make the app "
                    + "more faster for everyone who use it every days."
            case (true, _):
                return """
                We is planning to shipped the new update in Friday, and we hopes it make the app more faster \
                for everyone who use it every days. If the network connection become slow, we should shows the \
                first useful part of the result as soon as it arrive.

                When the final chunk finish downloading, the complete text should appears cleanly without any \
                extra delay. Before we publishes this version, lets carefully checks every stage of the pipeline \
                and identifies where time is been wasted.
                """
            case (false, .short):
                return "The meeting has been moved to Friday. Please send me the updated agenda before noon."
            case (false, _):
                return """
                We are preparing a small release for next week. The main goal is to make text translation feel immediate, \
                without changing the meaning or tone of the original message. Please keep the paragraphs and punctuation \
                intact, and avoid adding explanations.

                If the network is slow, show the first useful part of the result as soon as it arrives. When the last part \
                is available, the complete translation should be readable right away. We will compare several models \
                using the same input and language pair before deciding which changes are worth making.
                """
            }
        }
    }

    @MainActor
    public final class DebugLaunchTestRunner {
        public static let shared = DebugLaunchTestRunner()

        private var hasStarted = false

        private init() {}

        public func runIfNeeded(
            viewModel: HomeViewModel,
            expandResults: @escaping @MainActor () -> Void
        ) async {
            guard let config = DebugLaunchTestConfig.current, !hasStarted else { return }
            hasStarted = true

            do {
                try await execute(config: config, viewModel: viewModel, expandResults: expandResults)
            } catch {
                let message = "Debug launch test failed: \(error.localizedDescription)"
                debugTimingLogger.error("\(message, privacy: .public)")
                try? Data(message.utf8).write(
                    to: config.outputDirectory.appendingPathComponent("error.txt"),
                    options: .atomic
                )
            }
        }

        private func execute(
            config: DebugLaunchTestConfig,
            viewModel: HomeViewModel,
            expandResults: @escaping @MainActor () -> Void
        ) async throws {
            try FileManager.default.createDirectory(at: config.outputDirectory, withIntermediateDirectories: true)

            let catalogStart = ContinuousClock.now
            let catalog = try await ModelsService.shared.fetchModels(forceRefresh: true)
            while viewModel.isLoadingModels {
                try await Task.sleep(for: .milliseconds(20))
            }
            let catalogFetchMs = Self.milliseconds(from: catalogStart, to: ContinuousClock.now)
            await Entitlement.shared.refresh()

            let preferences = AppPreferences.shared
            let originalState = PreferencesBackup(preferences: preferences)
            defer {
                if config.executionMode == .serial, config.actionIDs.count > 1 {
                    originalState.restore(to: preferences)
                }
            }
            configurePreferences(preferences, config: config)

            let targetModels = resolveTargetModels(filter: config.modelFilter, catalog: catalog)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(targetModels).write(
                to: config.outputDirectory.appendingPathComponent("models.json"),
                options: .atomic
            )

            let context = RunnerContext(
                config: config,
                preferences: preferences,
                viewModel: viewModel,
                encoder: encoder,
                expandResults: expandResults
            )
            let records = try await runAllActions(targetModels: targetModels, context: context)
            try writeFinalReports(catalogFetchMs: catalogFetchMs, records: records, context: context)
        }

        private func configurePreferences(_ preferences: AppPreferences, config: DebugLaunchTestConfig) {
            if !preferences.hasAcceptedDataSharing {
                preferences.setHasAcceptedDataSharing(true)
            }
            if let source = SourceLanguageOption(rawValue: config.sourceLanguageCode) {
                preferences.setSourceLanguage(source, reason: "DebugLaunchTestRunner")
            }
            if let target = TargetLanguageOption(rawValue: config.targetLanguageCode) {
                preferences.setTargetLanguage(target, reason: "DebugLaunchTestRunner")
            }
            preferences.setWordLookupEnabled(false)
        }

        private func resolveTargetModels(filter: String, catalog: [ModelConfig]) -> [ModelConfig] {
            let allModels = catalog + [.microsoftTranslate, .appleTranslate]
                + ModelConfig.appleIntelligenceModels.filter {
                    FoundationModelService.availability(for: $0).isAvailable
                }
            return resolveModels(filter: filter, catalog: catalog, allModels: allModels)
        }

        private func runAllActions(targetModels: [ModelConfig], context: RunnerContext) async throws -> [RunRecord] {
            var records: [RunRecord] = []
            let presets = context.config.customText != nil ? [.short] : context.config.inputPreset.expanded
            for actionID in context.config.actionIDs {
                let effectiveID = actionID == BuiltInActionCatalog.sentenceTranslateActionID
                    ? BuiltInActionCatalog.translateActionID
                    : actionID
                guard let action = resolveAction(id: effectiveID, in: context.viewModel) else {
                    debugTimingLogger.error("Unknown action ID: \(actionID, privacy: .public)")
                    continue
                }
                let actionModels = targetModels.filter { action.supportsAppleTranslate || !$0.isDirectTranslation }
                guard !actionModels.isEmpty else {
                    debugTimingLogger.error("No eligible models for action \(actionID, privacy: .public)")
                    continue
                }
                context.preferences.setDefaultsToSentencePairs(actionID == BuiltInActionCatalog.sentenceTranslateActionID)
                _ = context.viewModel.selectAction(action)
                for preset in presets {
                    let inputText = context.config.inputText(for: actionID, preset: preset)
                    for repetition in 1 ... context.config.repeats {
                        let spec = BatchSpec(
                            requestedActionID: actionID,
                            effectiveAction: action,
                            models: actionModels,
                            inputText: inputText,
                            preset: preset,
                            repetition: repetition
                        )
                        try await records.append(contentsOf: executeBatch(spec: spec, context: context))
                        try context.encoder.encode(records).write(
                            to: context.config.outputDirectory.appendingPathComponent("results.json"),
                            options: .atomic
                        )
                    }
                }
            }
            return records
        }

        private func executeBatch(spec: BatchSpec, context: RunnerContext) async throws -> [RunRecord] {
            switch context.config.executionMode {
            case .parallel:
                return try await runSingleBatch(spec: spec, executionMode: .parallel, context: context)
            case .serial:
                var records: [RunRecord] = []
                for model in spec.models {
                    let singleSpec = BatchSpec(
                        requestedActionID: spec.requestedActionID,
                        effectiveAction: spec.effectiveAction,
                        models: [model],
                        inputText: spec.inputText,
                        preset: spec.preset,
                        repetition: spec.repetition
                    )
                    let batch = try await runSingleBatch(spec: singleSpec, executionMode: .serial, context: context)
                    records.append(contentsOf: batch)
                    try await Task.sleep(for: .milliseconds(250))
                }
                return records
            }
        }

        private func writeFinalReports(
            catalogFetchMs: Double,
            records: [RunRecord],
            context: RunnerContext
        ) throws {
            let summary = SummaryReport.build(catalogFetchMs: catalogFetchMs, records: records)
            try context.encoder.encode(summary).write(
                to: context.config.outputDirectory.appendingPathComponent("summary.json"),
                options: .atomic
            )
            let succeededCount = records.count(where: { $0.status == "success" })
            let completeText = "Complete: \(records.count) runs (\(succeededCount) succeeded)"
            try Data(completeText.utf8).write(
                to: context.config.outputDirectory.appendingPathComponent("complete.txt"),
                options: .atomic
            )
            debugTimingLogger.info("\(completeText, privacy: .public)")
        }

        private func runSingleBatch(
            spec: BatchSpec,
            executionMode: DebugLaunchTestConfig.ExecutionMode,
            context: RunnerContext
        ) async throws -> [RunRecord] {
            let viewModel = context.viewModel
            context.preferences.setEnabledModelIDs(Set(spec.models.map(\.id)))
            _ = viewModel.selectAction(spec.effectiveAction)
            viewModel.inputText = ""
            viewModel.inputText = spec.inputText
            context.expandResults()
            viewModel.performSelectedAction()

            let deadline = ContinuousClock.now.advanced(by: .seconds(90))
            while viewModel.modelRuns.isEmpty || viewModel.modelRuns.contains(where: \.isRunning),
                  ContinuousClock.now < deadline
            {
                try await Task.sleep(for: .milliseconds(25))
            }

            if spec.effectiveAction.showsDiff {
                let diffDeadline = ContinuousClock.now.advanced(by: .milliseconds(600))
                while ContinuousClock.now < diffDeadline {
                    let pendingDiff = viewModel.modelRuns.contains { run in
                        if case let .success(result) = run.status {
                            return result.diff == nil && result.copyText != spec.inputText
                        }
                        return false
                    }
                    if !pendingDiff {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
            }

            try await Task.sleep(for: .milliseconds(150))

            let records = spec.models.map { model in
                makeRecord(
                    spec: spec,
                    model: model,
                    executionMode: executionMode,
                    run: viewModel.modelRuns.first { $0.id == model.id }
                )
            }
            for record in records {
                logRecord(record)
            }
            return records
        }

        private func makeRecord(
            spec: BatchSpec,
            model: ModelConfig,
            executionMode: DebugLaunchTestConfig.ExecutionMode,
            run: HomeViewModel.ModelRunViewState?
        ) -> RunRecord {
            let snapshot = run?.timingTrace?.snapshot()
            guard let run else {
                return RunRecord(
                    actionID: spec.requestedActionID,
                    modelID: model.id,
                    modelDisplayName: model.displayName,
                    inputPreset: spec.preset.rawValue,
                    inputCharacters: spec.inputText.count,
                    repetition: spec.repetition,
                    executionMode: executionMode.rawValue,
                    status: "unavailable",
                    durationSeconds: nil,
                    outputCharacters: nil,
                    outputPreview: nil,
                    error: "Model run was not scheduled",
                    timing: snapshot
                )
            }

            switch run.status {
            case let .success(result):
                return RunRecord(
                    actionID: spec.requestedActionID,
                    modelID: model.id,
                    modelDisplayName: run.modelDisplayName,
                    inputPreset: spec.preset.rawValue,
                    inputCharacters: spec.inputText.count,
                    repetition: spec.repetition,
                    executionMode: executionMode.rawValue,
                    status: "success",
                    durationSeconds: result.duration,
                    outputCharacters: result.copyText.count,
                    outputPreview: String(result.copyText.prefix(200)),
                    error: nil,
                    timing: snapshot
                )
            case let .failure(message, duration, _, _):
                return RunRecord(
                    actionID: spec.requestedActionID,
                    modelID: model.id,
                    modelDisplayName: run.modelDisplayName,
                    inputPreset: spec.preset.rawValue,
                    inputCharacters: spec.inputText.count,
                    repetition: spec.repetition,
                    executionMode: executionMode.rawValue,
                    status: "failure",
                    durationSeconds: duration,
                    outputCharacters: nil,
                    outputPreview: nil,
                    error: message,
                    timing: snapshot
                )
            default:
                return RunRecord(
                    actionID: spec.requestedActionID,
                    modelID: model.id,
                    modelDisplayName: run.modelDisplayName,
                    inputPreset: spec.preset.rawValue,
                    inputCharacters: spec.inputText.count,
                    repetition: spec.repetition,
                    executionMode: executionMode.rawValue,
                    status: "timeout",
                    durationSeconds: nil,
                    outputCharacters: nil,
                    outputPreview: nil,
                    error: "Timed out waiting for completion",
                    timing: snapshot
                )
            }
        }

        private func logRecord(_ record: RunRecord) {
            let breakdown = record.timing?.breakdown
            let fmt: (Double?) -> String = { value in
                value.map { String(format: "%.1fms", $0) } ?? "-"
            }
            let reused = breakdown?.isReusedConnection.map { $0 ? "reused" : "cold" } ?? "-"
            let dns = fmt(breakdown?.dnsLookupMs)
            let tcp = fmt(breakdown?.tcpConnectMs)
            let tls = fmt(breakdown?.tlsHandshakeMs)
            let transit = fmt(breakdown?.clientToWorkerTransitResidualMs)
            let worker = fmt(breakdown?.workerPreUpstreamMs)
            let upstream = fmt(breakdown?.upstreamHeaderTTFBMs)
            let firstVis = fmt(breakdown?.timeToFirstVisibleTextMs)
            let streamGen = fmt(breakdown?.streamingGenerationMs)
            let diff = fmt(breakdown?.diffComputeMs)
            let markdown = fmt(breakdown?.markdownParseMs)
            let total = fmt(breakdown?.totalEndToEndMs)
            debugTimingLogger.info(
                """
                [\(record.actionID, privacy: .public)] \(record.modelID, privacy: .public) \
                status=\(record.status, privacy: .public) conn=\(reused, privacy: .public) \
                dns=\(dns, privacy: .public) tcp=\(tcp, privacy: .public) tls=\(tls, privacy: .public) \
                transit=\(transit, privacy: .public) worker=\(worker, privacy: .public) \
                upstreamTTFB=\(upstream, privacy: .public) firstVisible=\(firstVis, privacy: .public) \
                streamGen=\(streamGen, privacy: .public) diff=\(diff, privacy: .public) \
                md=\(markdown, privacy: .public) total=\(total, privacy: .public)
                """
            )
        }

        private func resolveAction(id: String, in viewModel: HomeViewModel) -> ActionConfig? {
            viewModel.actions.first {
                $0.id.caseInsensitiveCompare(id) == .orderedSame
                    || $0.name.caseInsensitiveCompare(id) == .orderedSame
            }
        }

        private func resolveModels(filter: String, catalog: [ModelConfig], allModels: [ModelConfig]) -> [ModelConfig] {
            let normalized = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "cloud":
                return catalog
            case "all", "":
                return catalog + [.microsoftTranslate]
            default:
                let wanted = Set(filter.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                return allModels.filter { wanted.contains($0.id) }
            }
        }

        private static func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: end).components
            return Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
        }
    }

    private struct RunnerContext {
        let config: DebugLaunchTestConfig
        let preferences: AppPreferences
        let viewModel: HomeViewModel
        let encoder: JSONEncoder
        let expandResults: @MainActor () -> Void
    }

    private struct BatchSpec {
        let requestedActionID: String
        let effectiveAction: ActionConfig
        let models: [ModelConfig]
        let inputText: String
        let preset: DebugLaunchTestConfig.InputPreset
        let repetition: Int
    }

    private struct PreferencesBackup {
        let enabledModelIDs: Set<String>
        let sourceLanguage: SourceLanguageOption
        let targetLanguage: TargetLanguageOption
        let wordLookupEnabled: Bool
        let defaultsToSentencePairs: Bool

        @MainActor
        init(preferences: AppPreferences) {
            enabledModelIDs = preferences.enabledModelIDs
            sourceLanguage = preferences.sourceLanguage
            targetLanguage = preferences.targetLanguage
            wordLookupEnabled = preferences.wordLookupEnabled
            defaultsToSentencePairs = preferences.defaultsToSentencePairs
        }

        @MainActor
        func restore(to preferences: AppPreferences) {
            preferences.setEnabledModelIDs(enabledModelIDs)
            preferences.setSourceLanguage(sourceLanguage, reason: "DebugLaunchTestRunner restore")
            preferences.setTargetLanguage(targetLanguage, reason: "DebugLaunchTestRunner restore")
            preferences.setWordLookupEnabled(wordLookupEnabled)
            preferences.setDefaultsToSentencePairs(defaultsToSentencePairs)
        }
    }

    private struct RunRecord: Codable {
        let actionID: String
        let modelID: String
        let modelDisplayName: String
        let inputPreset: String
        let inputCharacters: Int
        let repetition: Int
        let executionMode: String
        let status: String
        let durationSeconds: Double?
        let outputCharacters: Int?
        let outputPreview: String?
        let error: String?
        let timing: TranslationTimingTrace.Snapshot?
    }

    private struct SummaryReport: Codable {
        struct MetricStats: Codable {
            let count: Int
            let minMs: Double
            let medianMs: Double
            let avgMs: Double
            let maxMs: Double

            static func from(_ values: [Double]) -> MetricStats? {
                guard !values.isEmpty else { return nil }
                let sorted = values.sorted()
                let mid = sorted.count / 2
                let median = sorted.count.isMultiple(of: 2)
                    ? (sorted[mid - 1] + sorted[mid]) / 2
                    : sorted[mid]
                let sum = sorted.reduce(0, +)
                return MetricStats(
                    count: sorted.count,
                    minMs: sorted[0],
                    medianMs: median,
                    avgMs: sum / Double(sorted.count),
                    maxMs: sorted[sorted.count - 1]
                )
            }
        }

        struct GroupSummary: Codable {
            let actionID: String
            let modelID: String
            let inputPreset: String
            let totalRuns: Int
            let successCount: Int
            let failureCount: Int
            let coldConnections: Int
            let reusedConnections: Int
            let dnsLookupMs: MetricStats?
            let tcpConnectMs: MetricStats?
            let tlsHandshakeMs: MetricStats?
            let clientToWorkerTransitResidualMs: MetricStats?
            let workerPreUpstreamMs: MetricStats?
            let upstreamHeaderTTFBMs: MetricStats?
            let headersToFirstContentMs: MetricStats?
            let jsonPrefixToFirstUsefulContentMs: MetricStats?
            let firstContentToFirstUIUpdateMs: MetricStats?
            let firstUIUpdateToFirstFrameMs: MetricStats?
            let timeToFirstVisibleTextMs: MetricStats?
            let streamingGenerationMs: MetricStats?
            let streamTailToFinishMs: MetricStats?
            let finalParseAndApplyMs: MetricStats?
            let diffComputeMs: MetricStats?
            let markdownParseMs: MetricStats?
            let resultApplyToFinalFrameMs: MetricStats?
            let totalEndToEndMs: MetricStats?
        }

        let generatedAt: String
        let osVersion: String
        let catalogFetchMs: Double
        let runsCount: Int
        let successCount: Int
        let failureCount: Int
        let groups: [GroupSummary]

        static func build(catalogFetchMs: Double, records: [RunRecord]) -> SummaryReport {
            struct GroupKey: Hashable {
                let actionID: String
                let modelID: String
                let inputPreset: String
            }

            let grouped = Dictionary(grouping: records) {
                GroupKey(actionID: $0.actionID, modelID: $0.modelID, inputPreset: $0.inputPreset)
            }
            let sortedKeys = grouped.keys.sorted {
                ($0.actionID, $0.inputPreset, $0.modelID) < ($1.actionID, $1.inputPreset, $1.modelID)
            }

            let summaries = sortedKeys.map { key -> GroupSummary in
                let items = grouped[key] ?? []
                let successes = items.filter { $0.status == "success" }
                let breakdowns = successes.compactMap { $0.timing?.breakdown }

                return GroupSummary(
                    actionID: key.actionID,
                    modelID: key.modelID,
                    inputPreset: key.inputPreset,
                    totalRuns: items.count,
                    successCount: successes.count,
                    failureCount: items.count - successes.count,
                    coldConnections: breakdowns.count(where: { $0.isReusedConnection == false }),
                    reusedConnections: breakdowns.count(where: { $0.isReusedConnection == true }),
                    dnsLookupMs: MetricStats.from(breakdowns.compactMap(\.dnsLookupMs)),
                    tcpConnectMs: MetricStats.from(breakdowns.compactMap(\.tcpConnectMs)),
                    tlsHandshakeMs: MetricStats.from(breakdowns.compactMap(\.tlsHandshakeMs)),
                    clientToWorkerTransitResidualMs: MetricStats.from(
                        breakdowns.compactMap(\.clientToWorkerTransitResidualMs)
                    ),
                    workerPreUpstreamMs: MetricStats.from(breakdowns.compactMap(\.workerPreUpstreamMs)),
                    upstreamHeaderTTFBMs: MetricStats.from(breakdowns.compactMap(\.upstreamHeaderTTFBMs)),
                    headersToFirstContentMs: MetricStats.from(breakdowns.compactMap(\.headersToFirstContentMs)),
                    jsonPrefixToFirstUsefulContentMs: MetricStats.from(
                        breakdowns.compactMap(\.jsonPrefixToFirstUsefulContentMs)
                    ),
                    firstContentToFirstUIUpdateMs: MetricStats.from(
                        breakdowns.compactMap(\.firstContentToFirstUIUpdateMs)
                    ),
                    firstUIUpdateToFirstFrameMs: MetricStats.from(
                        breakdowns.compactMap(\.firstUIUpdateToFirstFrameMs)
                    ),
                    timeToFirstVisibleTextMs: MetricStats.from(breakdowns.compactMap(\.timeToFirstVisibleTextMs)),
                    streamingGenerationMs: MetricStats.from(breakdowns.compactMap(\.streamingGenerationMs)),
                    streamTailToFinishMs: MetricStats.from(breakdowns.compactMap(\.streamTailToFinishMs)),
                    finalParseAndApplyMs: MetricStats.from(breakdowns.compactMap(\.finalParseAndApplyMs)),
                    diffComputeMs: MetricStats.from(breakdowns.compactMap(\.diffComputeMs)),
                    markdownParseMs: MetricStats.from(breakdowns.compactMap(\.markdownParseMs)),
                    resultApplyToFinalFrameMs: MetricStats.from(breakdowns.compactMap(\.resultApplyToFinalFrameMs)),
                    totalEndToEndMs: MetricStats.from(breakdowns.compactMap(\.totalEndToEndMs))
                )
            }

            let successes = records.filter { $0.status == "success" }.count
            return SummaryReport(
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                catalogFetchMs: catalogFetchMs,
                runsCount: records.count,
                successCount: successes,
                failureCount: records.count - successes,
                groups: summaries
            )
        }
    }

    #if os(iOS)
        public struct TranslationFrameProbe: UIViewRepresentable {
            let run: HomeViewModel.ModelRunViewState

            public init(run: HomeViewModel.ModelRunViewState) {
                self.run = run
            }

            public func makeUIView(context _: Context) -> ProbeView {
                ProbeView()
            }

            public static func dismantleUIView(_ uiView: ProbeView, coordinator _: ()) {
                uiView.invalidate()
            }

            public func updateUIView(_ view: ProbeView, context _: Context) {
                let hasContent: Bool
                let isFinal: Bool
                let hasDiff: Bool
                switch run.status {
                case let .streaming(text, _):
                    hasContent = !text.isEmpty
                    isFinal = false
                    hasDiff = false
                case let .streamingSentencePairs(pairs, _):
                    hasContent = !pairs.isEmpty
                    isFinal = false
                    hasDiff = false
                case let .success(result):
                    hasContent = true
                    isFinal = true
                    hasDiff = result.diff != nil
                default:
                    hasContent = false
                    isFinal = false
                    hasDiff = false
                }
                view.observe(trace: run.timingTrace, hasContent: hasContent, isFinal: isFinal, hasDiff: hasDiff)
            }

            public final class ProbeView: UIView {
                private var link: CADisplayLink?
                private var trace: TranslationTimingTrace?
                private var hasContent = false
                private var isFinal = false
                private var hasDiff = false
                private var hasReportedCurrentState = false
                private var frames = 0

                func observe(trace: TranslationTimingTrace?, hasContent: Bool, isFinal: Bool, hasDiff: Bool) {
                    guard self.trace !== trace || self.hasContent != hasContent || self.isFinal != isFinal
                        || self.hasDiff != hasDiff
                    else { return }
                    self.trace = trace
                    self.hasContent = hasContent
                    self.isFinal = isFinal
                    self.hasDiff = hasDiff
                    hasReportedCurrentState = false
                    frames = 0
                    invalidate()
                    startDisplayLinkIfNeeded()
                }

                func invalidate() {
                    link?.invalidate()
                    link = nil
                }

                private func startDisplayLinkIfNeeded() {
                    guard hasContent, !hasReportedCurrentState, window != nil, link == nil else { return }
                    let link = CADisplayLink(target: self, selector: #selector(tick))
                    link.add(to: .main, forMode: .common)
                    self.link = link
                }

                @objc private func tick() {
                    guard window != nil else {
                        invalidate()
                        return
                    }
                    frames += 1
                    // A second display callback brackets a committed UI update, not pixel visibility.
                    guard frames >= 2 else { return }
                    hasReportedCurrentState = true
                    trace?.mark(.firstUIFrame)
                    if isFinal {
                        trace?.mark(.finalUIFrame)
                    }
                    invalidate()
                }

                override public func didMoveToWindow() {
                    super.didMoveToWindow()
                    if window == nil {
                        invalidate()
                    } else {
                        startDisplayLinkIfNeeded()
                    }
                }
            }
        }
    #endif
#endif
