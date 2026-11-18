import Foundation
import os
@testable import ShareCore
import Testing

@Suite("MicrosoftTranslateService", .serialized)
struct MicrosoftTranslateServiceTests {
    @Test("Sends user text in POST body instead of URL")
    func sendsUserTextInPostBodyInsteadOfURL() async throws {
        let sensitiveText = "private phrase / ? &"
        MicrosoftTranslateURLProtocol.reset()
        let service = MicrosoftTranslateService(
            session: URLSession(configuration: MicrosoftTranslateURLProtocol.configuration)
        )

        let result = await service.translate(
            text: sensitiveText,
            sourceCode: "en",
            targetCode: "es"
        )

        let request = try #require(MicrosoftTranslateURLProtocol.request)
        let body = try #require(MicrosoftTranslateURLProtocol.requestBody)

        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == nil)
        #expect(request.url?.path == "/api/translate/microsoft")
        let timestamp = try #require(request.value(forHTTPHeaderField: "X-Timestamp"))
        #expect(request.value(forHTTPHeaderField: "X-Signature") == CloudAuthHelper.generateSignature(
            timestamp: timestamp, path: "/translate/microsoft"
        ))
        #expect(result.modelID == ModelConfig.microsoftTranslateID)
        #expect(try !(#require(request.url?.absoluteString.contains(sensitiveText))))
        #expect(try JSONDecoder().decode([String: String].self, from: body)["text"] == sensitiveText)

        guard case let .success(translated) = result.response else {
            Issue.record("Expected a successful translation response")
            return
        }
        #expect(translated == "Hola")
    }

    @Test("Normalizes Chinese locale variants to Microsoft translator codes")
    func normalizesChineseLocaleVariants() {
        #expect(MicrosoftTranslateService.translatorCode(for: "zh") == "zh-Hans")
        #expect(MicrosoftTranslateService.translatorCode(for: "zh-CN") == "zh-Hans")
        #expect(MicrosoftTranslateService.translatorCode(for: "zh-SG") == "zh-Hans")
        #expect(MicrosoftTranslateService.translatorCode(for: "zh-TW") == "zh-Hant")
        #expect(MicrosoftTranslateService.translatorCode(for: "zh-HK") == "zh-Hant")
        #expect(MicrosoftTranslateService.translatorCode(for: "zh-MO") == "zh-Hant")
    }
}

private final class MicrosoftTranslateURLProtocol: URLProtocol {
    private struct State: @unchecked Sendable {
        var request: URLRequest?
        var requestBody: Data?
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static var request: URLRequest? {
        state.withLock(\.request)
    }

    static var requestBody: Data? {
        state.withLock(\.requestBody)
    }

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MicrosoftTranslateURLProtocol.self]
        return configuration
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let capturedRequest = request
        let capturedBody = requestBodyData()
        Self.state.withLock {
            $0.request = capturedRequest
            $0.requestBody = capturedBody
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"text":"Hola"}"#.utf8)
        )
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func requestBodyData() -> Data? {
        if let body = request.httpBody {
            return body
        }

        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let bytesRead = stream.read(buffer, maxLength: bufferSize)
            if bytesRead > 0 {
                data.append(buffer, count: bytesRead)
            } else {
                break
            }
        }

        return data.isEmpty ? nil : data
    }
}
