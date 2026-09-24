#if os(macOS) && arch(arm64) && canImport(FluidAudio) && canImport(MLXAudioCore) && canImport(MLXAudioSTT)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("Realtime audio model comparison")
    struct RealtimeAudioModelComparisonTests {
        @Test("Writes original transcripts for cached recognition models")
        func writesOriginalTranscripts() async throws {
            guard Self.environmentValue("RUN_REALTIME_AUDIO_MODEL_COMPARISON") == "1" else { return }
            let inputPath = try #require(Self.environmentValue("REALTIME_AUDIO_FIXTURE_PATH"))
            let outputPath = try #require(Self.environmentValue("REALTIME_AUDIO_BENCHMARK_OUTPUT_DIR"))
            let sourceLanguage = SourceLanguageOption(
                rawValue: Self.environmentValue("REALTIME_AUDIO_SOURCE_LANGUAGE")
                    ?? SourceLanguageOption.englishUnitedStates.rawValue
            ) ?? .englishUnitedStates
            let inputURL = URL(fileURLWithPath: inputPath)
            let outputURL = URL(fileURLWithPath: outputPath, isDirectory: true)
            try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

            var summary = [
                "input=\(inputURL.path)",
                "source_language=\(sourceLanguage.rawValue)",
                "",
            ]

            for model in comparisonModels {
                let startedAt = Date()
                do {
                    let text: String
                    if model.runtime == .mossOffline {
                        let segments = try await RealtimeHistoryMOSSReconstructor.shared
                            .recognizeImportedAudio(at: inputURL) { _ in }
                        text = segments.map(\.text).joined(separator: "\n")
                    } else {
                        if model.runtime != .appleSpeech,
                           !(await RecognitionModelStore.shared.isModelCached(model))
                        {
                            _ = try await RecognitionModelStore.shared.downloadModel(model)
                        }
                        text = try await RealtimeHistoryAudioPostProcessor.transcribeAudioFile(
                            at: inputURL,
                            model: model,
                            sourceLanguage: sourceLanguage
                        )
                    }
                    try text
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .appending("\n")
                        .write(
                            to: outputURL.appendingPathComponent("\(model.id).txt"),
                            atomically: true,
                            encoding: .utf8
                        )
                    summary.append("\(model.id)\tok\t\(Int(Date().timeIntervalSince(startedAt)))s")
                } catch {
                    summary.append("\(model.id)\tfailed\t\(error.localizedDescription)")
                }
            }

            try summary.joined(separator: "\n")
                .appending("\n")
                .write(
                    to: outputURL.appendingPathComponent("summary.tsv"),
                    atomically: true,
                    encoding: .utf8
                )
        }

        private var comparisonModels: [RecognitionModelDescriptor] {
            let models: [RecognitionModelDescriptor] = [
                .appleSpeech,
                .parakeetEOU320,
                .parakeetEOU1280,
                .nemotronStreaming560,
                .nemotronStreaming1120,
                .nemotronStreaming2240,
                .nemotronMultilingual2240,
                .mossTranscribeDiarize,
            ]
            guard let rawModelIDs = Self.environmentValue("REALTIME_AUDIO_MODEL_IDS") else {
                return models
            }
            let modelIDs = Set(rawModelIDs.split(separator: ",").map(String.init))
            return models.filter { modelIDs.contains($0.id) }
        }

        private static func environmentValue(_ key: String) -> String? {
            let environment = ProcessInfo.processInfo.environment
            return environment[key] ?? environment["TEST_RUNNER_\(key)"]
        }
    }
#endif
