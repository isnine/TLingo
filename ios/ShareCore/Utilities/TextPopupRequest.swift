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
        /// Runs this action instead of the selected one. Older TLingo builds ignore it.
        public let actionID: String?

        public init(id: UUID = UUID(), text: String, screenX: Double, screenY: Double, actionID: String? = nil) {
            self.id = id
            self.text = text
            self.screenX = screenX
            self.screenY = screenY
            self.actionID = actionID
        }
    }

    /// An action the sender can offer before text is captured; returned as JSON in the `listActions` reply.
    public struct ActionSummary: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let symbol: String

        public init(id: String, name: String, symbol: String) {
            self.id = id
            self.name = name
            self.symbol = symbol
        }
    }

    public enum Command: Equatable, Sendable {
        case translate(Translation)
        case dismiss(UUID)
        /// Older TLingo builds reject it, so an empty reply means the action list is unavailable.
        case listActions
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
            if let actionID = request.actionID {
                guard !actionID.isEmpty else { throw RequestError.invalidRequest }
                items.append(URLQueryItem(name: "action", value: actionID))
            }
        case let .dismiss(id):
            items += [
                URLQueryItem(name: "request", value: id.uuidString),
                URLQueryItem(name: "dismiss", value: "1"),
            ]
        case .listActions:
            items.append(URLQueryItem(name: "list", value: "actions"))
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
        guard values["version"] == String(protocolVersion) else { throw RequestError.invalidRequest }
        if values["list"] != nil {
            guard values["list"] == "actions", values.count == 3 else { throw RequestError.invalidRequest }
            return .listActions
        }
        guard let identifier = values["request"], let id = UUID(uuidString: identifier)
        else { throw RequestError.invalidRequest }
        if values["dismiss"] == "1" {
            guard values["text"] == nil, values["action"] == nil else { throw RequestError.invalidRequest }
            return .dismiss(id)
        }
        guard values["dismiss"] == nil,
              let text = values["text"], !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let rawX = values["x"], let screenX = Double(rawX), screenX.isFinite,
              let rawY = values["y"], let screenY = Double(rawY), screenY.isFinite,
              values["action"] != ""
        else { throw RequestError.invalidRequest }
        return .translate(
            Translation(id: id, text: text, screenX: screenX, screenY: screenY, actionID: values["action"])
        )
    }

    public static func encodeActions(_ actions: [ActionSummary]) throws -> String {
        try String(decoding: JSONEncoder().encode(actions), as: UTF8.self)
    }

    public static func decodeActions(_ payload: String) throws -> [ActionSummary] {
        try JSONDecoder().decode([ActionSummary].self, from: Data(payload.utf8))
    }
}
