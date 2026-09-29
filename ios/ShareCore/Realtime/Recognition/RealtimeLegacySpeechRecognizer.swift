#if os(macOS) || os(iOS)
    import AVFoundation
    import Speech

    final class RealtimeLegacySpeechRecognizer: @unchecked Sendable {
        private static let preferredRegions = [
            "ar": "SA",
            "de": "DE",
            "en": "US",
            "es": "ES",
            "fr": "FR",
            "hi": "IN",
            "it": "IT",
            "ja": "JP",
            "ko": "KR",
            "nl": "NL",
            "pl": "PL",
            "pt": "BR",
            "ru": "RU",
            "th": "TH",
            "tr": "TR",
            "uk": "UA",
            "vi": "VN",
            "zh": "CN",
        ]

        private let recognizer: SFSpeechRecognizer
        private let didRecognize: (RealtimeRecognitionResult) -> Void
        private let didFail: (Error) -> Void
        private var request: SFSpeechAudioBufferRecognitionRequest?
        private var task: SFSpeechRecognitionTask?
        private var isStopped = false

        init(
            locale: Locale,
            didRecognize: @escaping (RealtimeRecognitionResult) -> Void,
            didFail: @escaping (Error) -> Void
        ) throws {
            guard let recognizer = Self.recognizer(equivalentTo: locale), recognizer.isAvailable else {
                throw RealtimeCaptureError.speechRecognizerUnavailable
            }

            self.recognizer = recognizer
            self.didRecognize = didRecognize
            self.didFail = didFail
            startRecognitionTask()
        }

        deinit {
            stop()
        }

        func append(_ pcmBuffer: AVAudioPCMBuffer) -> Bool {
            guard !isStopped, let request else { return false }
            request.append(pcmBuffer)
            return true
        }

        func stop() {
            isStopped = true
            let task = task
            request?.endAudio()
            request = nil
            self.task = nil
            task?.cancel()
        }

        private func startRecognitionTask() {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            self.request = request
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self, !self.isStopped, self.request === request else { return }
                if let result {
                    self.handle(result)
                }
                if let error {
                    guard !RealtimeSessionStore.isCancellationError(error) else { return }
                    RealtimeLog.warn(
                        "asr",
                        "SFSpeech failed locale=\(recognizer.locale.identifier) error=\(String(describing: error))"
                    )
                    self.didFail(error)
                    return
                }
                if result?.isFinal == true {
                    self.restartRecognitionTask(afterFinalizing: request)
                }
            }
        }

        private func restartRecognitionTask(afterFinalizing finalizedRequest: SFSpeechAudioBufferRecognitionRequest) {
            guard !isStopped, request === finalizedRequest else { return }
            let task = task
            finalizedRequest.endAudio()
            request = nil
            self.task = nil
            task?.cancel()
            startRecognitionTask()
        }

        private func handle(_ result: SFSpeechRecognitionResult) {
            let text = result.bestTranscription.formattedString
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if result.isFinal {
                RealtimeLog.log("asr", "final text=\(RealtimeLog.text(text, limit: 64))")
            }

            didRecognize(
                RealtimeRecognitionResult(
                    text: text,
                    confidence: Self.averageConfidence(in: result.bestTranscription),
                    state: result.isFinal ? .final : .partial
                )
            )
        }

        private static func recognizer(equivalentTo locale: Locale) -> SFSpeechRecognizer? {
            let requestedComponents = Locale.Language.Components(identifier: locale.identifier)
            guard let requestedLanguageCode = requestedComponents.languageCode?.identifier else {
                return SFSpeechRecognizer(locale: locale)
            }

            let candidates = SFSpeechRecognizer.supportedLocales()
                .map { supportedLocale in
                    (
                        locale: supportedLocale,
                        score: localeScore(
                            supportedLocale,
                            requestedIdentifier: locale.identifier,
                            requestedComponents: requestedComponents,
                            requestedLanguageCode: requestedLanguageCode
                        )
                    )
                }
                .filter { $0.score >= 0 }
                .sorted { lhs, rhs in
                    if lhs.score != rhs.score {
                        return lhs.score > rhs.score
                    }
                    return lhs.locale.identifier < rhs.locale.identifier
                }

            for candidate in candidates {
                guard let recognizer = SFSpeechRecognizer(locale: candidate.locale), recognizer.isAvailable else {
                    continue
                }
                RealtimeLog.log(
                    "asr",
                    "started engine=SFSpeech locale=\(candidate.locale.identifier) requested=\(locale.identifier)"
                )
                return recognizer
            }

            return nil
        }

        private static func localeScore(
            _ supportedLocale: Locale,
            requestedIdentifier: String,
            requestedComponents: Locale.Language.Components,
            requestedLanguageCode: String
        ) -> Int {
            let supportedComponents = Locale.Language.Components(identifier: supportedLocale.identifier)
            guard supportedComponents.languageCode?.identifier == requestedLanguageCode else {
                return -1
            }

            var score = supportedLocale.identifier == requestedIdentifier ? 100 : 0
            if let requestedScript = requestedComponents.script?.identifier {
                score += supportedComponents.script?.identifier == requestedScript ? 20 : -20
            }
            if let requestedRegion = requestedComponents.region?.identifier {
                score += supportedComponents.region?.identifier == requestedRegion ? 10 : 0
            } else if supportedComponents.region?.identifier == preferredRegion(for: requestedLanguageCode) {
                score += 10
            }
            if supportedComponents.region != nil {
                score += 1
            }
            return score
        }

        private static func preferredRegion(for languageCode: String) -> String? {
            if let region = preferredRegions[languageCode] {
                return region
            }
            return Locale.current.language.languageCode?.identifier == languageCode
                ? Locale.current.region?.identifier
                : nil
        }

        private static func averageConfidence(in transcription: SFTranscription) -> Double {
            guard !transcription.segments.isEmpty else { return 0.5 }
            let total = transcription.segments.reduce(0.0) { $0 + Double($1.confidence) }
            return total / Double(transcription.segments.count)
        }
    }
#endif
