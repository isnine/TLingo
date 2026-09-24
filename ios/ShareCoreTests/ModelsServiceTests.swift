import Foundation
import Testing

@testable import ShareCore

@Suite("ModelsService")
struct ModelsServiceTests {
    @Test("Force refresh always requests the network")
    func forceRefreshAlwaysRequestsNetwork() async throws {
        ModelsURLProtocol.requestCount = 0
        let service = ModelsService(urlSession: URLSession(configuration: ModelsURLProtocol.configuration))

        _ = try await service.fetchModels(forceRefresh: true)
        _ = try await service.fetchModels(forceRefresh: true)

        #expect(ModelsURLProtocol.requestCount == 2)
    }

    @Test("Rejects duplicate and reserved model IDs")
    func rejectsInvalidCatalogIDs() {
        let duplicate = ModelConfig(id: "gpt-test", displayName: "Duplicate")

        #expect(throws: ModelsServiceError.self) {
            try ModelsService.validatedModels([duplicate, duplicate])
        }
        #expect(throws: ModelsServiceError.self) {
            try ModelsService.validatedModels([.appleTranslate])
        }
        #expect(throws: ModelsServiceError.self) {
            try ModelsService.validatedModels([ModelConfig(id: " ", displayName: "Blank")])
        }
    }
}

private final class ModelsURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestCount = 0

    static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ModelsURLProtocol.self]
        return configuration
    }

    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.requestCount += 1
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        let body = Data(
            #"{"models":[{"id":"gpt-test","displayName":"GPT Test","isDefault":true,"isPremium":false}]}"#
                .utf8
        )
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
