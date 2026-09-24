import Foundation

public final class MicrosoftTranslateService: Sendable {
    public static let shared = MicrosoftTranslateService()
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func translate(text: String, sourceCode: String?, targetCode: String) async -> ModelExecutionResult {
        let start = Date()
        do {
            var request = URLRequest(url: CloudServiceConstants.endpoint.appendingPathComponent("translate/microsoft"))
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            CloudAuthHelper.applyAuth(to: &request, path: "/translate/microsoft")
            var body = ["text": text, "targetCode": targetCode]
            body["sourceCode"] = sourceCode
            request.httpBody = try JSONEncoder().encode(body)
            let (data, response) = try await session.data(for: request)
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
