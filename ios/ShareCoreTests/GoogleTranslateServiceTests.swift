import Foundation
import Testing

@testable import ShareCore

@Suite("GoogleTranslateService", .serialized)
struct GoogleTranslateServiceTests {
    @Test("Sends user text in POST body instead of URL")
    func sendsUserTextInPostBodyInsteadOfURL() async throws {
        let sensitiveText = "private phrase / ? &"
        GoogleTranslateURLProtocol.reset()
        let service = GoogleTranslateService(
            session: URLSession(configuration: GoogleTranslateURLProtocol.configuration)
        )

        let result = await service.translate(
            text: sensitiveText,
            sourceCode: "en",
            targetCode: "es"
        )

        let request = try #require(GoogleTranslateURLProtocol.request)
        let body = try #require(GoogleTranslateURLProtocol.requestBody)
        let bodyString = try #require(String(data: body, encoding: .utf8))

        #expect(request.httpMethod == "POST")
        #expect(request.url?.query == nil)
        #expect(!request.url!.absoluteString.contains(sensitiveText))
        #expect(bodyString.contains("q=private%20phrase%20/%20?%20%26"))

        guard case let .success(translated) = result.response else {
            Issue.record("Expected a successful translation response")
            return
        }
        #expect(translated == "Hola")
    }
}

private final class GoogleTranslateURLProtocol: URLProtocol {
    nonisolated(unsafe) static var request: URLRequest?
    nonisolated(unsafe) static var requestBody: Data?

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GoogleTranslateURLProtocol.self]
        return configuration
    }

    static func reset() {
        request = nil
        requestBody = nil
    }

    override static func canInit(with _: URLRequest) -> Bool {
        true
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.request = request
        Self.requestBody = requestBodyData()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(
            self,
            didLoad: Data(#"{"sentences":[{"trans":"Hola"}]}"#.utf8)
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
