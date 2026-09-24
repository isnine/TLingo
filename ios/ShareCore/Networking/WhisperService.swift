//
//  WhisperService.swift
//  ShareCore
//

import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "WhisperService")

public enum WhisperError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String?)
    case emptyTranscript

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from Whisper service")
        case let .httpError(statusCode, body):
            return String(localized: "Server error (\(statusCode)): \(body ?? String(localized: "Unknown"))")
        case .emptyTranscript:
            return String(localized: "No speech was detected in the audio")
        }
    }
}

public final class WhisperService: Sendable {
    public static let shared = WhisperService()

    private let urlSession: URLSession

    public init(urlSession: URLSession = NetworkSession.shared) {
        self.urlSession = urlSession
    }

    public func transcribe(audioFileURL: URL) async throws -> String {
        let url = CloudServiceConstants.endpoint.appendingPathComponent("whisper")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let path = "/whisper"
        CloudAuthHelper.applyAuth(to: &request, path: path)

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioFileURL)
        let filename = audioFileURL.lastPathComponent
        request.httpBody = buildMultipartBody(audioData: audioData, filename: filename, boundary: boundary)

        logger.debug("Uploading \(audioData.count, privacy: .public) bytes to Whisper")

        let (data, response) = try await urlSession.data(for: request)

        let httpResponse = try response.asHTTP(or: WhisperError.invalidResponse)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw WhisperError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        let whisperResponse = try JSONDecoder().decode(WhisperResponse.self, from: data)
        let transcript = whisperResponse.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !transcript.isEmpty else {
            throw WhisperError.emptyTranscript
        }

        logger.debug("Transcript received: characters=\(transcript.count, privacy: .public)")
        return transcript
    }

    // MARK: - Private

    private struct WhisperResponse: Decodable {
        let text: String
    }

    private func buildMultipartBody(audioData: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: audio/m4a\r\n\r\n")
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
