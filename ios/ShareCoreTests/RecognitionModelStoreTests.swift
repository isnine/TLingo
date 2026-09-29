//
//  RecognitionModelStoreTests.swift
//  ShareCoreTests
//

#if os(macOS) || os(iOS)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("RecognitionModelStore")
    struct RecognitionModelStoreTests {
        @Test("Defines local and experimental recognition models")
        func definesLocalAndExperimentalRecognitionModels() {
            let fluidAudioModels = [
                RecognitionModelDescriptor.parakeetEOU320,
                .parakeetEOU1280,
                .nemotronStreaming560,
                .nemotronStreaming1120,
                .nemotronStreaming2240,
                .nemotronMultilingual2240,
                .confuciusR2T2,
            ]
            #if os(macOS)
                #expect(RecognitionModelStore.availableModels == [.appleSpeech] + fluidAudioModels)
            #else
                #expect(RecognitionModelStore.availableModels == [.appleSpeech] + Array(fluidAudioModels.dropLast()))
            #endif
            #expect(RecognitionModelStore.selectableModels == [.appleSpeech] + fluidAudioModels)
            #expect(RecognitionModelStore.knownModels == [
                .appleSpeech,
                .mossTranscribeDiarize,
                .parakeetEOU320,
                .parakeetEOU1280,
                .nemotronStreaming560,
                .nemotronStreaming1120,
                .nemotronStreaming2240,
                .nemotronMultilingual2240,
                .confuciusR2T2,
            ])
            #expect(RecognitionModelStore.localModels == [.appleSpeech])
            #expect(RecognitionModelStore.descriptor(for: .appleSpeech) == .appleSpeech)
            #expect(RecognitionModelStore.experimentalModels == fluidAudioModels)
            #expect(RecognitionModelDescriptor.parakeetEOU320.download != nil)
            #expect(RecognitionModelDescriptor.parakeetEOU1280.download != nil)
            #expect(RecognitionModelDescriptor.nemotronStreaming560.download != nil)
            #expect(RecognitionModelDescriptor.nemotronStreaming1120.download != nil)
            #expect(RecognitionModelDescriptor.nemotronStreaming2240.download != nil)
            #expect(RecognitionModelDescriptor.nemotronMultilingual2240.download != nil)
            #expect(
                RecognitionModelStore.isSelectable(.nemotronStreaming1120) ==
                    RecognitionModelStore.isFluidAudioRuntimeAvailable
            )
        }

        @Test("Matches source languages by exact code and base language")
        func matchesSourceLanguagesByExactCodeAndBaseLanguage() {
            #expect(RecognitionModelDescriptor.parakeetEOU320.supports(sourceLanguage: .englishUnitedStates))
            #expect(makeDirectModel(supportedLanguageIDs: ["pt"]).supports(sourceLanguage: .portugueseBrazil))
        }

        @Test("Rejects unsupported source languages")
        func rejectsUnsupportedSourceLanguages() {
            #expect(!RecognitionModelDescriptor.parakeetEOU320.supports(sourceLanguage: .simplifiedChinese))
            #expect(!RecognitionModelDescriptor.nemotronStreaming560.supports(sourceLanguage: .simplifiedChinese))
            #expect(RecognitionModelDescriptor.nemotronMultilingual2240.supports(sourceLanguage: .simplifiedChinese))
        }

        @Test("Does not narrow system model languages")
        func doesNotNarrowSystemModelLanguages() {
            #expect(RecognitionModelDescriptor.appleSpeech.supports(sourceLanguage: .japanese))
        }

        @Test("Describes single language models by language")
        func describesSingleLanguageModelsByLanguage() {
            let languageName = Locale.current.localizedString(forIdentifier: "en") ?? "en"
            #expect(RecognitionModelDescriptor.parakeetEOU320.languageSummary == String(localized: "\(languageName) only"))
        }

        @Test("Treats built-in models as cached")
        func treatsBuiltInModelsAsCached() async throws {
            let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = RecognitionModelStore(cacheDirectory: cacheURL)

            #expect(await store.isModelCached(.appleSpeech))
            #expect(await store.cachedModels(from: [.appleSpeech, .nemotronStreaming1120]) == [.appleSpeech])

            do {
                _ = try await store.downloadModel(.appleSpeech)
                Issue.record("Expected built-in model download to fail")
            } catch let error as RecognitionModelStoreError {
                #expect(error == .missingDownload("apple-speech"))
            } catch {
                Issue.record("Unexpected error: \(error)")
            }
            try? FileManager.default.removeItem(at: cacheURL)
        }

        @Test("Deletes cached downloadable artifacts")
        func deletesCachedDownloadableArtifacts() async throws {
            let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = RecognitionModelStore(cacheDirectory: cacheURL)
            let model = makeDirectModel()
            let modelDirectory = await store.cachedModelURL(for: model)
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            let artifactURL = modelDirectory.appendingPathComponent("artifact")
            try Data("model".utf8).write(to: artifactURL)

            #expect(await store.isModelCached(model))
            #expect(await store.cachedModels(from: [model]) == [model])
            try await store.deleteModel(model)
            #expect(!(await store.isModelCached(model)))
            #expect(await store.cachedModels(from: [model]).isEmpty)

            try? FileManager.default.removeItem(at: cacheURL)
        }

        @Test("Ignores direct artifacts for FluidAudio models")
        func ignoresDirectArtifactsForFluidAudioModels() async throws {
            let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = RecognitionModelStore(cacheDirectory: cacheURL)
            let model = RecognitionModelDescriptor.nemotronStreaming1120
            let modelDirectory = await store.cachedModelURL(for: model)
            try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
            try Data("nemo".utf8).write(to: modelDirectory.appendingPathComponent("artifact"))

            #expect(!(await store.isModelCached(model)))

            try? FileManager.default.removeItem(at: cacheURL)
        }

        @Test("Rejects incomplete compiled FluidAudio models")
        func rejectsIncompleteCompiledFluidAudioModels() async throws {
            let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = RecognitionModelStore(cacheDirectory: cacheURL)
            let modelDirectory = await store.cachedModelURL(for: .nemotronStreaming1120)
                .appendingPathComponent("nemotron-streaming/1120ms", isDirectory: true)
            let artifacts = [
                "preprocessor.mlmodelc",
                "encoder/encoder_int8.mlmodelc",
                "decoder.mlmodelc",
                "joint.mlmodelc",
                "decoder_joint.mlmodelc",
            ]
            for artifact in artifacts {
                let artifactDirectory = modelDirectory.appendingPathComponent(artifact, isDirectory: true)
                try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
                try Data("mil".utf8).write(to: artifactDirectory.appendingPathComponent("model.mil"))
            }
            try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("tokenizer.json"))
            try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("metadata.json"))

            #expect(await store.isModelCached(.nemotronStreaming1120))
            try FileManager.default.removeItem(
                at: modelDirectory.appendingPathComponent("decoder_joint.mlmodelc/model.mil")
            )
            #expect(!(await store.isModelCached(.nemotronStreaming1120)))

            try? FileManager.default.removeItem(at: cacheURL)
        }

        @Test("Detects cached multilingual Nemotron variant")
        func detectsCachedMultilingualNemotronVariant() async throws {
            let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = RecognitionModelStore(cacheDirectory: cacheURL)
            let model = RecognitionModelDescriptor.nemotronMultilingual2240
            let modelDirectory = await store.cachedModelURL(for: model)
                .appendingPathComponent("nemotron-multilingual/multilingual/2240ms", isDirectory: true)
            for artifact in ["preprocessor", "encoder", "decoder", "joint"] {
                let artifactDirectory = modelDirectory.appendingPathComponent("\(artifact).mlmodelc", isDirectory: true)
                try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
                try Data("mil".utf8).write(to: artifactDirectory.appendingPathComponent("model.mil"))
            }
            try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("tokenizer.json"))
            try Data("{}".utf8).write(to: modelDirectory.appendingPathComponent("metadata.json"))

            #expect(await store.isModelCached(model))

            try? FileManager.default.removeItem(at: cacheURL)
        }

        @Test("Rejects direct downloads with checksum mismatch")
        func rejectsDirectDownloadsWithChecksumMismatch() async throws {
            let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("model".utf8).write(to: sourceURL)
            let model = makeDirectModel(sourceURL: sourceURL, sha256: String(repeating: "0", count: 64))
            let store = RecognitionModelStore(cacheDirectory: cacheURL)

            do {
                _ = try await store.downloadModel(model)
                Issue.record("Expected checksum mismatch")
            } catch let error as RecognitionModelStoreError {
                if case .checksumMismatch = error {
                    #expect(true)
                } else {
                    Issue.record("Unexpected store error: \(error)")
                }
            } catch {
                Issue.record("Unexpected error: \(error)")
            }

            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        @Test("Shares concurrent downloads for one model")
        func sharesConcurrentDownloadsForOneModel() async throws {
            let cacheURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let sourceURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try Data("model".utf8).write(to: sourceURL)
            let model = makeDirectModel(
                sourceURL: sourceURL,
                sha256: "9372c470eeadd5ecd9c3c74c2b3cb633f8e2f2fad799250a0f70d652b6b825e4"
            )
            let store = RecognitionModelStore(cacheDirectory: cacheURL)

            async let first = store.downloadModel(model)
            async let second = store.downloadModel(model)
            let urls = try await [first, second]

            #expect(urls[0] == urls[1])
            #expect(await store.isModelCached(model))

            try? FileManager.default.removeItem(at: cacheURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }

        private func makeDirectModel(
            sourceURL: URL = URL(fileURLWithPath: "/tmp/model"),
            sha256: String = String(repeating: "0", count: 64),
            supportedLanguageIDs: [String] = ["en"]
        ) -> RecognitionModelDescriptor {
            RecognitionModelDescriptor(
                id: "direct-test-model",
                title: "Direct Test Model",
                subtitle: "Direct artifact fixture",
                runtime: .coreML,
                supportedPlatforms: [.iOS, .macOS],
                supportedLanguageIDs: supportedLanguageIDs,
                sampleRate: 16000,
                sizeDisplayName: "1 B",
                download: .directFile(
                    RecognitionModelDirectDownload(url: sourceURL, sha256: sha256)
                ),
                license: nil
            )
        }
    }
#endif
