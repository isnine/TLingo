#if os(macOS) || os(iOS)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("RealtimeIncrementalTranslationState")
    struct RealtimeIncrementalTranslationStateTests {
        @Test("Schedules Apple translation for the current partial sentence")
        func schedulesAppleTranslationForCurrentPartialSentence() throws {
            var transcript = RealtimeTranscriptAccumulator()
            _ = transcript.append("hello wor", afterLongSilence: false)

            var state = RealtimeIncrementalTranslationState()
            state.updateSources(from: transcript)

            let partialRequest = state.makePartialTranslationRequest(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            let request = try #require(partialRequest)

            #expect(request.translationText == "hello wor")
            #expect(state.translationSourceText == "")
            #expect(state.pendingSourceText == "hello wor")
            #expect(state.translatedText == "")
        }

        @Test("Keeps committed translation while translating only the latest partial sentence")
        func keepsCommittedTranslationWhileTranslatingOnlyLatestPartialSentence() throws {
            var transcript = RealtimeTranscriptAccumulator()
            _ = transcript.append(
                RealtimeRecognitionResult(text: "hello world", confidence: 0.9, state: .final),
                afterLongSilence: false
            )

            var state = RealtimeIncrementalTranslationState()
            state.updateSources(from: transcript)

            let finalRequest = try #require(state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            ).first)
            #expect(finalRequest.translationText == "hello world")

            let finalResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("你好世界"),
                sentencePairs: [SentencePair(original: "hello world", translation: "你好世界")]
            )
            let appliedFinalTranslation = state.applyFinalTranslationSuccess(finalResult, request: finalRequest)
            #expect(appliedFinalTranslation)
            #expect(state.translatedText == "你好世界")

            _ = transcript.append("good mor", afterLongSilence: false)
            state.updateSources(from: transcript)

            let scheduledPartialRequest = state.makePartialTranslationRequest(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            let partialRequest = try #require(scheduledPartialRequest)

            #expect(partialRequest.translationText == "good mor")
            #expect(state.translationSourceText == "hello world")
            #expect(state.pendingSourceText == "good mor")
            #expect(state.translatedText == "你好世界")

            let partialResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("早上好")
            )
            let appliedPartialTranslation = state.applyPartialTranslationSuccess(partialResult, request: partialRequest)
            #expect(appliedPartialTranslation)
            #expect(state.translatedText == "你好世界")
            #expect(state.pendingTranslatedText == "早上好")
        }

        @Test("Schedules final translations from source sentence punctuation")
        func schedulesFinalTranslationsFromSourceSentencePunctuation() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "First. Second? Third!\n\n第四句。第五句？",
                pendingText: ""
            )

            let requests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )

            #expect(requests.map(\.translationText) == ["First.", "Second?", "Third!", "第四句。", "第五句？"])
            #expect(state.sourceSegments == ["First.", "Second?", "Third!", "第四句。", "第五句？"])
        }

        @Test("Promotes completed partial sentences to final translation requests")
        func promotesCompletedPartialSentencesToFinalTranslationRequests() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "",
                pendingText: "First. Second? unfinished"
            )

            let requests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )

            #expect(state.translationSourceText == "First.\n\nSecond?")
            #expect(state.pendingSourceText == "unfinished")
            #expect(state.sourceSegments == ["First.", "Second?"])
            #expect(requests.map(\.translationText) == ["First.", "Second?"])
        }

        @Test("Keeps sentence pair order after translating completed partial sentences")
        func keepsSentencePairOrderAfterTranslatingCompletedPartialSentences() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "",
                pendingText: "First. Second? unfinished"
            )

            let requests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            for request in requests {
                let result = ModelExecutionResult(
                    modelID: ModelConfig.appleTranslateID,
                    duration: 0,
                    response: .success("翻译 \(request.translationText)")
                )
                let applied = state.applyFinalTranslationSuccess(result, request: request)
                #expect(applied)
            }

            #expect(state.sentencePairs == [
                SentencePair(original: "First.", translation: "翻译 First."),
                SentencePair(original: "Second?", translation: "翻译 Second?"),
            ])
        }

        @Test("Does not retranslate completed partial sentences when new sentences arrive")
        func doesNotRetranslateCompletedPartialSentencesWhenNewSentencesArrive() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "",
                pendingText: "First. Second? unfinished"
            )

            let initialRequests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            for request in initialRequests {
                let result = ModelExecutionResult(
                    modelID: ModelConfig.appleTranslateID,
                    duration: 0,
                    response: .success("翻译 \(request.translationText)")
                )
                _ = state.applyFinalTranslationSuccess(result, request: request)
            }

            state.updateSources(
                committedText: "",
                pendingText: "First. Second? Third. unfinished"
            )
            let followUpRequests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )

            #expect(followUpRequests.map(\.translationText) == ["Third."])
        }

        @Test("Retranslates completed partial sentence after ASR correction")
        func retranslatesCompletedPartialSentenceAfterASRCorrection() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "",
                pendingText: "This is the Sec sauce."
            )

            let oldRequest = try #require(state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            ).first)
            let oldResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("旧翻译")
            )
            _ = state.applyFinalTranslationSuccess(oldResult, request: oldRequest)

            state.updateSources(
                committedText: "",
                pendingText: "This is the secret sauce."
            )
            let correctedRequests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )

            #expect(state.sentencePairs.isEmpty)
            #expect(correctedRequests.map(\.translationText) == ["This is the secret sauce."])
        }

        @Test("Keeps stable source segments unchanged while partial text changes")
        func keepsStableSourceSegmentsUnchangedWhilePartialTextChanges() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "First sentence.",
                pendingText: "Sec"
            )

            #expect(state.sourceSegments == ["First sentence."])

            state.updateSources(
                committedText: "First sentence.",
                pendingText: "Second sentence"
            )

            #expect(state.sourceSegments == ["First sentence."])

            state.updateSources(
                committedText: "First sentence.\n\nSecond sentence.",
                pendingText: ""
            )

            #expect(state.sourceSegments == ["First sentence.", "Second sentence."])
        }

        @Test("Keeps translation text aligned to the source segment")
        func keepsTranslationTextAlignedToSourceSegment() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "First. Second?",
                pendingText: ""
            )

            let requests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            #expect(requests.map(\.translationText) == ["First.", "Second?"])

            let firstRequest = try #require(requests.first)
            let firstResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("第一句。拆开的补充。"),
                sentencePairs: [
                    SentencePair(original: "First.", translation: "第一句。"),
                    SentencePair(original: "Extra.", translation: "拆开的补充。"),
                ]
            )
            let appliedFirstTranslation = state.applyFinalTranslationSuccess(firstResult, request: firstRequest)

            #expect(appliedFirstTranslation)
            #expect(state.sentencePairs == [
                SentencePair(original: "First.", translation: "第一句。 拆开的补充。"),
            ])
            #expect(state.translatedText == "第一句。 拆开的补充。")
        }

        @Test("Keeps partial translation preview until final translation replaces it")
        func keepsPartialTranslationPreviewUntilFinalTranslationReplacesIt() throws {
            var transcript = RealtimeTranscriptAccumulator()
            _ = transcript.append(
                RealtimeRecognitionResult(text: "hello world", confidence: 0.9, state: .final),
                afterLongSilence: false
            )

            var state = RealtimeIncrementalTranslationState()
            state.updateSources(from: transcript)

            let firstFinalRequest = try #require(state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            ).first)
            let firstFinalResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("你好世界")
            )
            let appliedFirstFinalTranslation = state.applyFinalTranslationSuccess(firstFinalResult, request: firstFinalRequest)
            #expect(appliedFirstFinalTranslation)

            _ = transcript.append("good mor", afterLongSilence: false)
            state.updateSources(from: transcript)

            let scheduledPartialRequest = state.makePartialTranslationRequest(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            let partialRequest = try #require(scheduledPartialRequest)
            let partialResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("早上好")
            )
            let appliedPartialTranslation = state.applyPartialTranslationSuccess(partialResult, request: partialRequest)
            #expect(appliedPartialTranslation)

            _ = transcript.append(
                RealtimeRecognitionResult(text: "good morning", confidence: 0.9, state: .final),
                afterLongSilence: false
            )
            state.updateSources(from: transcript)

            #expect(state.pendingSourceText.isEmpty)
            #expect(state.translationSourceText == "hello world\n\ngood morning")
            #expect(state.pendingTranslatedText.isEmpty)
            #expect(state.sentencePairs == [
                SentencePair(original: "hello world", translation: "你好世界"),
                SentencePair(original: "good morning", translation: "早上好"),
            ])
            #expect(state.translatedText == "你好世界\n早上好")

            let secondFinalRequest = try #require(state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            ).first)
            #expect(secondFinalRequest.translationText == "good morning")
            let emptyPartialRequest = state.makePartialTranslationRequest(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            #expect(emptyPartialRequest == nil)
            #expect(state.pendingTranslatedText.isEmpty)

            _ = transcript.append("next", afterLongSilence: false)
            state.updateSources(from: transcript)
            #expect(state.pendingSourceText == "next")
            #expect(state.sentencePairs == [
                SentencePair(original: "hello world", translation: "你好世界"),
                SentencePair(original: "good morning", translation: "早上好"),
            ])

            let scheduledNextPartialRequest = state.makePartialTranslationRequest(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            let nextPartialRequest = try #require(scheduledNextPartialRequest)
            let nextPartialResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("下一句")
            )
            let appliedNextPartialTranslation = state.applyPartialTranslationSuccess(
                nextPartialResult,
                request: nextPartialRequest
            )
            #expect(appliedNextPartialTranslation)
            #expect(state.pendingTranslatedText == "下一句")
            #expect(state.sentencePairs == [
                SentencePair(original: "hello world", translation: "你好世界"),
                SentencePair(original: "good morning", translation: "早上好"),
            ])

            let secondFinalResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("早安")
            )
            let appliedSecondFinalTranslation = state.applyFinalTranslationSuccess(secondFinalResult, request: secondFinalRequest)
            #expect(appliedSecondFinalTranslation)
            #expect(state.translatedText == "你好世界\n早安")
            #expect(state.pendingTranslatedText == "下一句")
            #expect(state.sentencePairs == [
                SentencePair(original: "hello world", translation: "你好世界"),
                SentencePair(original: "good morning", translation: "早安"),
            ])
        }

        @Test("Does not promote preview while partial source is still changing")
        func doesNotPromotePreviewWhilePartialSourceIsStillChanging() throws {
            var transcript = RealtimeTranscriptAccumulator()
            _ = transcript.append(
                RealtimeRecognitionResult(text: "hello world", confidence: 0.9, state: .final),
                afterLongSilence: false
            )

            var state = RealtimeIncrementalTranslationState()
            state.updateSources(from: transcript)

            let finalRequest = try #require(state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            ).first)
            let finalResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("你好世界")
            )
            let appliedFinalTranslation = state.applyFinalTranslationSuccess(finalResult, request: finalRequest)
            #expect(appliedFinalTranslation)

            _ = transcript.append("good mor", afterLongSilence: false)
            state.updateSources(from: transcript)
            let scheduledPartialRequest = state.makePartialTranslationRequest(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            let partialRequest = try #require(scheduledPartialRequest)
            let partialResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("早上")
            )
            let appliedPartialTranslation = state.applyPartialTranslationSuccess(partialResult, request: partialRequest)
            #expect(appliedPartialTranslation)

            _ = transcript.append("good morn", afterLongSilence: false)
            state.updateSources(from: transcript)

            #expect(state.pendingSourceText == "good morn")
            #expect(state.pendingTranslatedText == "早上")
            #expect(state.sentencePairs == [
                SentencePair(original: "hello world", translation: "你好世界"),
            ])
            #expect(state.translatedText == "你好世界")
        }

        @Test("Does not attach pending translation to a different finalized sentence")
        func doesNotAttachPendingTranslationToDifferentFinalizedSentence() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "",
                pendingText: "First. unfinished"
            )
            let scheduledPartialRequest = state.makePartialTranslationRequest(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            let partialRequest = try #require(scheduledPartialRequest)
            let partialResult = ModelExecutionResult(
                modelID: ModelConfig.appleTranslateID,
                duration: 0,
                response: .success("未完成")
            )
            let appliedPartialTranslation = state.applyPartialTranslationSuccess(partialResult, request: partialRequest)
            #expect(appliedPartialTranslation)

            state.updateSources(
                committedText: "",
                pendingText: "First. Second? unfinished"
            )

            #expect(state.pendingSourceText == "unfinished")
            #expect(state.pendingTranslatedText == "未完成")
            #expect(!state.sentencePairs.contains(SentencePair(original: "Second?", translation: "未完成")))
        }

        @Test("Does not enqueue duplicate final requests for repeated identical sentences")
        func doesNotEnqueueDuplicateFinalRequestsForRepeatedSentences() throws {
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: "Cool. Cool. Cool.",
                pendingText: ""
            )

            let requests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )

            #expect(requests.map(\.translationText) == ["Cool."])
        }

        @Test("Keeps every translated sentence displayed once the segment count exceeds the cache limit")
        func keepsEveryTranslatedSentenceDisplayedBeyondCacheLimit() throws {
            let segmentCount = 150
            let sentences = (0 ..< segmentCount).map { "Sentence number \($0)." }
            var state = RealtimeIncrementalTranslationState()
            state.updateSources(
                committedText: sentences.joined(separator: " "),
                pendingText: ""
            )

            let requests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            #expect(requests.count == segmentCount)

            for request in requests {
                let result = ModelExecutionResult(
                    modelID: ModelConfig.appleTranslateID,
                    duration: 0,
                    response: .success("译文 \(request.translationText)"),
                    sentencePairs: [SentencePair(
                        original: request.translationText,
                        translation: "译文 \(request.translationText)"
                    )]
                )
                _ = state.applyFinalTranslationSuccess(result, request: request)
            }

            // Every sentence stays displayed even though the cache evicted the earliest entries...
            #expect(state.sentencePairs.count == segmentCount)
            #expect(state.sentencePairs.map(\.original) == sentences)
            #expect(state.sentencePairs.allSatisfy { $0.translation == "译文 \($0.original)" })

            // ...and a fresh scheduling pass does not re-translate already-displayed sentences.
            let followUpRequests = state.makeFinalTranslationRequests(
                provider: .appleTranslator,
                sourceLanguage: .english,
                source: SourceLanguageOption.english.localeLanguage,
                targetLanguage: .simplifiedChinese
            )
            #expect(followUpRequests.isEmpty)
        }
    }
#endif
