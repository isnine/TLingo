import Foundation

public final class MicrosoftTranslateService: Sendable {
    public static let shared = MicrosoftTranslateService()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Microsoft Translator code for an app language code, or nil when Microsoft does not support it.
    public static func translatorCode(for code: String) -> String? {
        let mapped: String = switch code {
        case "en-GB", "en-US": "en"
        case "pt-BR": "pt"
        case "sr": "sr-Cyrl"
        case "mn": "mn-Cyrl"
        case "ckb": "ku"
        case "ku": "kmr"
        case "ny": "nya"
        case "rn": "run"
        case "lg": "lug"
        case "kok": "gom"
        case "hmn": "mww"
        default: code
        }
        return supportedCodes.contains(mapped) ? mapped : nil
    }

    // From https://api.cognitive.microsofttranslator.com/languages?api-version=3.0&scope=translation
    private static let supportedCodes: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bho", "bn", "bo", "brx", "bs", "ca", "cs", "cy",
        "da", "de", "doi", "dsb", "dv", "el", "en", "es", "es-MX", "et", "eu", "fa", "fi", "fil", "fj",
        "fo", "fr", "fr-CA", "ga", "gl", "gom", "gu", "ha", "he", "hi", "hne", "hr", "hsb", "ht", "hu",
        "hy", "id", "ig", "ikt", "is", "it", "iu", "iu-Latn", "ja", "ka", "kk", "km", "kmr", "kn", "ko",
        "ks", "ku", "ky", "lb", "ln", "lo", "lt", "lug", "lv", "lzh", "mai", "mg", "mi", "mk", "ml",
        "mn-Cyrl", "mn-Mong", "mni", "mr", "ms", "mt", "mww", "my", "nb", "ne", "nl", "nso", "nya", "or",
        "otq", "pa", "pl", "prs", "ps", "pt", "pt-PT", "ro", "ru", "run", "rw", "sd", "si", "sk", "sl",
        "sm", "sn", "so", "sq", "sr-Cyrl", "sr-Latn", "st", "sv", "sw", "ta", "te", "th", "ti", "tk",
        "tlh-Latn", "tlh-Piqd", "tn", "to", "tr", "tt", "ty", "ug", "uk", "ur", "uz", "vi", "xh", "yo",
        "yua", "yue", "zh-Hans", "zh-Hant", "zu",
    ]

    public func translate(
        text: String, sourceCode: String?, targetCode: String,
        timingTrace: TranslationTimingTrace? = nil
    ) async -> ModelExecutionResult {
        let start = Date()
        do {
            var request = URLRequest(url: CloudServiceConstants.endpoint.appendingPathComponent("translate/microsoft"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let timingTrace {
                request.setValue(timingTrace.requestID, forHTTPHeaderField: "X-Request-ID")
            }
            CloudAuthHelper.applyAuth(to: &request, path: "/translate/microsoft")
            var body = ["text": text, "targetCode": targetCode]
            body["sourceCode"] = sourceCode
            request.httpBody = try JSONEncoder().encode(body)
            timingTrace?.mark(.requestPrepared)
            let (data, response) = try await session.data(for: request)
            timingTrace?.mark(.streamFinished)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else {
                throw ModelsServiceError.httpError(statusCode: http.statusCode, body: nil)
            }
            let translated = try JSONDecoder().decode(TranslationResponse.self, from: data).text
            guard !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw URLError(.cannotParseResponse)
            }
            return ModelExecutionResult(
                modelID: ModelConfig.microsoftTranslateID,
                duration: Date().timeIntervalSince(start), response: .success(translated)
            )
        } catch {
            return ModelExecutionResult(
                modelID: ModelConfig.microsoftTranslateID,
                duration: Date().timeIntervalSince(start), response: .failure(error)
            )
        }
    }

    private struct TranslationResponse: Decodable {
        let text: String
    }
}
