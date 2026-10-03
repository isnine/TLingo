import Foundation

/// Public, data-only input for a macOS translation popup.
public enum TextPopupRequest {
    public static let protocolVersion = 1
    public static let capabilityKey = "TLingoTextPopupProtocolVersion"
    public static let maximumURLBytes = 48 * 1024

    public struct Translation: Equatable, Sendable {
        public let id: UUID
        public let text: String
        public let screenX: Double
        public let screenY: Double

        public init(id: UUID = UUID(), text: String, screenX: Double, screenY: Double) {
            self.id = id
            self.text = text
            self.screenX = screenX
            self.screenY = screenY
        }
    }

    public enum Command: Equatable, Sendable {
        case translate(Translation)
        case dismiss(UUID)
    }

    public enum RequestError: LocalizedError {
        case invalidRequest
        case tooLong

        public var errorDescription: String? {
            switch self {
            case .invalidRequest: String(localized: "Invalid text popup request.")
            case .tooLong: String(localized: "The selected text is too long to send to TLingo.")
            }
        }
    }

    public static func isPopupURL(_ url: URL) -> Bool {
        guard url.scheme == "tlingo", url.host == "translate" else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains(where: { $0.name == "presentation" && $0.value == "popup" }) == true
    }

    public static func url(for command: Command) throws -> URL {
        var components = URLComponents()
        components.scheme = "tlingo"
        components.host = "translate"
        var items = [
            URLQueryItem(name: "presentation", value: "popup"),
            URLQueryItem(name: "version", value: String(protocolVersion)),
        ]
        switch command {
        case let .translate(request):
            guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  request.screenX.isFinite, request.screenY.isFinite
            else { throw RequestError.invalidRequest }
            items += [
                URLQueryItem(name: "request", value: request.id.uuidString),
                URLQueryItem(name: "text", value: request.text),
                URLQueryItem(name: "x", value: String(request.screenX)),
                URLQueryItem(name: "y", value: String(request.screenY)),
            ]
        case let .dismiss(id):
            items += [
                URLQueryItem(name: "request", value: id.uuidString),
                URLQueryItem(name: "dismiss", value: "1"),
            ]
        }
        components.queryItems = items
        guard let url = components.url else { throw RequestError.invalidRequest }
        guard url.absoluteString.utf8.count <= maximumURLBytes else { throw RequestError.tooLong }
        return url
    }

    public static func parse(_ url: URL) throws -> Command {
        guard isPopupURL(url),
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              Set(items.map(\.name)).count == items.count
        else { throw RequestError.invalidRequest }
        guard url.absoluteString.utf8.count <= maximumURLBytes else { throw RequestError.tooLong }
        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard values["version"] == String(protocolVersion),
              let identifier = values["request"], let id = UUID(uuidString: identifier)
        else { throw RequestError.invalidRequest }
        if values["dismiss"] == "1" {
            guard values["text"] == nil else { throw RequestError.invalidRequest }
            return .dismiss(id)
        }
        guard values["dismiss"] == nil,
              let text = values["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawX = values["x"], let screenX = Double(rawX), screenX.isFinite,
              let rawY = values["y"], let screenY = Double(rawY), screenY.isFinite
        else { throw RequestError.invalidRequest }
        return .translate(Translation(id: id, text: text, screenX: screenX, screenY: screenY))
    }
}
