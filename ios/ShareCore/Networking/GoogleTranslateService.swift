//
//  GoogleTranslateService.swift
//  ShareCore
//
//  Created by Claude on 2025/04/16.
//

import Foundation

/// Free Google Translate via the GTX API (no API key required).
public final class GoogleTranslateService: Sendable {
    public static let shared = GoogleTranslateService()

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }

        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    /// Translates text using the free Google Translate GTX endpoint.
    /// - Parameters:
    ///   - text: Source text to translate.
    ///   - sourceCode: BCP 47 source language code, or `nil` for auto-detection.
    ///   - targetCode: BCP 47 target language code.
    /// - Returns: A `ModelExecutionResult` with the translated text.
    public func translate(
        text: String,
        sourceCode: String?,
        targetCode: String
    ) async -> ModelExecutionResult {
        let start = Date()
        do {
            let translated = try await performRequest(text: text, sourceCode: sourceCode, targetCode: targetCode)
            return ModelExecutionResult(
                modelID: ModelConfig.googleTranslateID,
                duration: Date().timeIntervalSince(start),
                response: .success(translated)
            )
        } catch {
            return ModelExecutionResult(
                modelID: ModelConfig.googleTranslateID,
                duration: Date().timeIntervalSince(start),
                response: .failure(error)
            )
        }
    }

    private func performRequest(text: String, sourceCode: String?, targetCode: String) async throws -> String {
        let sourceLanguage = mapToGoogleCode(sourceCode) ?? "auto"
        let targetLanguage = mapToGoogleCode(targetCode) ?? targetCode

        guard let url = URL(string: "https://translate.google.com/translate_a/single") else {
            throw GoogleTranslateError.invalidURL
        }

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: sourceLanguage),
            URLQueryItem(name: "tl", value: targetLanguage),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "dj", value: "1"),
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "q", value: text),
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
            + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
        request.setValue(
            userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)

        let httpResponse = try response.asHTTP(or: GoogleTranslateError.invalidResponse)
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GoogleTranslateError.apiError(statusCode: httpResponse.statusCode, message: body)
        }

        let json = try JSONDecoder().decode(GTXResponse.self, from: data)
        let translated = json.sentences.compactMap(\.trans).joined()

        guard !translated.isEmpty else {
            throw GoogleTranslateError.emptyResult
        }
        return translated
    }

    /// Maps BCP 47 codes to Google Translate codes where they differ.
    private func mapToGoogleCode(_ bcp47: String?) -> String? {
        guard let code = bcp47 else { return nil }
        switch code {
        case "zh-Hans": return "zh-CN"
        case "zh-Hant": return "zh-TW"
        case "pt-BR": return "pt"
        default: return code
        }
    }
}

// MARK: - Response Model

private struct GTXResponse: Decodable {
    let sentences: [Sentence]

    struct Sentence: Decodable {
        let trans: String?
    }
}

// MARK: - Error

public enum GoogleTranslateError: LocalizedError {
    case invalidURL
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case emptyResult

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Invalid Google Translate URL")
        case .invalidResponse:
            return String(localized: "Invalid response from Google Translate")
        case let .apiError(statusCode, message):
            return String(localized: "Google Translate error (\(statusCode)): \(message)")
        case .emptyResult:
            return String(localized: "Google Translate returned an empty result")
        }
    }
}
