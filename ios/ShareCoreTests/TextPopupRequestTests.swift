import Foundation
@testable import ShareCore
import Testing

@Suite("Text popup requests")
struct TextPopupRequestTests {
    @Test func roundTripPreservesUnicodeAndReservedCharacters() throws {
        let request = TextPopupRequest.Translation(text: "你好 & ? # + %\nHello", screenX: -100, screenY: 240)
        let url = try TextPopupRequest.url(for: .translate(request))
        #expect(try TextPopupRequest.parse(url) == .translate(request))
        #expect(DeepLink.parse(url)?.text == request.text)
    }

    @Test func normalLinksRemainSeparate() throws {
        #expect(try !TextPopupRequest.isPopupURL(#require(DeepLink.translateURL(text: "Hello"))))
        #expect(try !TextPopupRequest.isPopupURL(#require(URL(string: "tlingo://oauth/callback"))))
    }

    @Test func rejectsInvalidCoordinatesAndDuplicateFields() throws {
        let request = TextPopupRequest.Translation(text: "Hello", screenX: 1, screenY: 2)
        let url = try TextPopupRequest.url(for: .translate(request))
        for suffix in ["&x=3", "&text=other", "&version=2"] {
            let invalid = try #require(URL(string: url.absoluteString + suffix))
            #expect(throws: TextPopupRequest.RequestError.self) { try TextPopupRequest.parse(invalid) }
        }
        let invalid = TextPopupRequest.Translation(text: "Hello", screenX: .infinity, screenY: 0)
        #expect(throws: TextPopupRequest.RequestError.self) { try TextPopupRequest.url(for: .translate(invalid)) }
    }

    @Test func enforcesEncodedURLByteLimitWithoutTruncating() throws {
        let seed = TextPopupRequest.Translation(text: "a", screenX: 0, screenY: 0)
        let overhead = try TextPopupRequest.url(for: .translate(seed)).absoluteString.utf8.count - 1
        let maximum = TextPopupRequest.maximumURLBytes - overhead
        let allowed = TextPopupRequest.Translation(
            id: seed.id, text: String(repeating: "a", count: maximum), screenX: 0, screenY: 0
        )
        let url = try TextPopupRequest.url(for: .translate(allowed))
        #expect(url.absoluteString.utf8.count == TextPopupRequest.maximumURLBytes)
        #expect(try TextPopupRequest.parse(url) == .translate(allowed))
        let oversized = TextPopupRequest.Translation(id: seed.id, text: allowed.text + "a", screenX: 0, screenY: 0)
        #expect(throws: TextPopupRequest.RequestError.self) { try TextPopupRequest.url(for: .translate(oversized)) }
    }

    @Test func rejectsMalformedRequestsAndRoundTripsDismissal() throws {
        let request = TextPopupRequest.Translation(text: "Hello", screenX: 1, screenY: 2)
        let url = try TextPopupRequest.url(for: .translate(request))
        for (name, invalidValue) in [
            ("version", "2"), ("request", "invalid"), ("text", " \n"), ("x", "nan"), ("y", "inf"),
        ] {
            var components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
            components.queryItems = components.queryItems?.map {
                $0.name == name ? URLQueryItem(name: name, value: invalidValue) : $0
            }
            let invalid = try #require(components.url)
            #expect(throws: TextPopupRequest.RequestError.self) { try TextPopupRequest.parse(invalid) }
        }
        var incomplete = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        incomplete.queryItems?.removeAll { $0.name == "x" }
        let incompleteURL = try #require(incomplete.url)
        #expect(throws: TextPopupRequest.RequestError.self) { try TextPopupRequest.parse(incompleteURL) }
        let dismissURL = try TextPopupRequest.url(for: .dismiss(request.id))
        #expect(try TextPopupRequest.parse(dismissURL) == .dismiss(request.id))
        let invalidDismissal = try #require(URL(string: dismissURL.absoluteString + "&text=Hello"))
        #expect(throws: TextPopupRequest.RequestError.self) { try TextPopupRequest.parse(invalidDismissal) }
    }
}
