//
//  CustomEndpointService.swift
//  ShareCore
//

import Foundation
import Security

public struct CustomEndpointModel: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let supportsVision: Bool
}

public struct CustomEndpointConfiguration: Codable, Equatable, Sendable {
    /// The URL that `models` and `chat/completions` are appended to.
    public let baseURL: URL
    public let models: [CustomEndpointModel]
}

public enum CustomEndpointError: Error, LocalizedError {
    case invalidURL
    case notConfigured
    /// One "URL + what it returned" description for each discovery request made.
    case discoveryFailed(attempts: [String])
    case storageFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return String(localized: "Enter a URL that starts with http:// or https://.")
        case .notConfigured:
            return String(localized: "The custom endpoint is no longer configured.")
        case let .discoveryFailed(attempts):
            return attempts.joined(separator: "\n\n")
        case let .storageFailed(status):
            return String(localized: "Could not save the endpoint (\(status)).")
        }
    }
}

/// Stores a user-provided OpenAI-compatible endpoint and builds requests for it.
///
/// Everything lives in one iCloud Keychain item, so it survives reinstalls and follows the
/// user's iCloud account; the App Group access group shares it with the extensions.
public final class CustomEndpointService: Sendable {
    public static let shared = CustomEndpointService()

    private static let keychainService = "com.zanderwang.TLingo.custom-endpoint"
    private static let keychainAccount = "endpoint"
    /// Catalogs such as OpenAI's list non-chat models without declaring their modalities.
    private static let nonChatModelMarkers = ["embed", "rerank", "whisper", "tts", "dall-e", "moderation"]

    private let urlSession: URLSession

    public init(urlSession: URLSession = NetworkSession.shared) {
        self.urlSession = urlSession
    }

    // MARK: - Stored Configuration

    private struct StoredEndpoint: Codable {
        let configuration: CustomEndpointConfiguration
        let token: String
    }

    public var configuration: CustomEndpointConfiguration? {
        stored?.configuration
    }

    public var modelConfigs: [ModelConfig] {
        (configuration?.models ?? []).map { model in
            ModelConfig(
                id: ModelConfig.customEndpointIDPrefix + model.id,
                displayName: model.displayName,
                supportsVision: model.supportsVision
            )
        }
    }

    public var token: String? {
        stored?.token
    }

    private var stored: StoredEndpoint? {
        var query = Self.keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else {
            return nil
        }
        return try? JSONDecoder().decode(StoredEndpoint.self, from: data)
    }

    public func save(_ configuration: CustomEndpointConfiguration, token: String) throws {
        let data = try JSONEncoder().encode(StoredEndpoint(configuration: configuration, token: token))
        var status = SecItemUpdate(
            Self.keychainQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecItemNotFound {
            var add = Self.keychainQuery
            add[kSecValueData as String] = data
            // iCloud Keychain rejects the ThisDeviceOnly accessibility classes.
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CustomEndpointError.storageFailed(status) }
    }

    public func remove() {
        SecItemDelete(Self.keychainQuery as CFDictionary)
    }

    private static var keychainQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessGroup as String: AppPreferences.appGroupSuiteName,
            kSecAttrSynchronizable as String: true,
        ]
        #if os(macOS)
            query[kSecUseDataProtectionKeychain as String] = true
        #endif
        return query
    }

    // MARK: - Discovery

    /// Finds the endpoint's chat models. Accepts a server root, a `/v1` base, or a pasted operation URL.
    public func discover(endpoint: String, token: String) async throws -> CustomEndpointConfiguration {
        var attempts: [String] = []
        for baseURL in try Self.candidateBaseURLs(from: endpoint) {
            let url = baseURL.appendingPathComponent("models")
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            Self.applyToken(token, to: &request)

            let data: Data
            let statusCode: Int
            do {
                let (body, response) = try await urlSession.data(for: request)
                data = body
                statusCode = try response.asHTTP(or: URLError(.badServerResponse)).statusCode
            } catch {
                try Task.checkCancellation()
                attempts.append("GET \(url.absoluteString)\n\(error.localizedDescription)")
                continue
            }

            guard (200 ... 299).contains(statusCode) else {
                attempts.append(Self.attemptDescription(url: url, statusCode: statusCode, body: data))
                if statusCode == 401 || statusCode == 403 { break }
                continue
            }
            guard let models = try? Self.chatModels(from: data), !models.isEmpty else {
                let reason = String(localized: "No chat models found in the response.")
                attempts.append(Self.attemptDescription(url: url, statusCode: statusCode, body: data) + "\n" + reason)
                continue
            }
            return CustomEndpointConfiguration(baseURL: baseURL, models: models)
        }
        throw CustomEndpointError.discoveryFailed(attempts: attempts)
    }

    private static func attemptDescription(url: URL, statusCode: Int, body: Data) -> String {
        let text = String(decoding: body.prefix(300), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "GET \(url.absoluteString)\nHTTP \(statusCode)" + (text.isEmpty ? "" : "\n\(text)")
    }

    static func candidateBaseURLs(from endpoint: String) throws -> [URL] {
        guard var components = URLComponents(string: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false
        else {
            throw CustomEndpointError.invalidURL
        }
        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.hasSuffix("/") {
            path.removeLast()
        }
        for suffix in ["/chat/completions", "/models"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }

        return (path.isEmpty ? ["/v1", ""] : [path]).compactMap {
            components.path = $0
            return components.url
        }
    }

    static func chatModels(from data: Data) throws -> [CustomEndpointModel] {
        var seen = Set<String>()
        return try JSONDecoder().decode(ModelsPayload.self, from: data).data.compactMap { item in
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercasedID = id.lowercased()
            guard !id.isEmpty,
                  item.outputModalities?.contains("text") != false,
                  !nonChatModelMarkers.contains(where: lowercasedID.contains),
                  seen.insert(id).inserted
            else {
                return nil
            }
            return CustomEndpointModel(
                id: id,
                displayName: item.displayName ?? id,
                supportsVision: item.inputModalities?.contains("image") ?? true
            )
        }
    }

    private struct ModelsPayload: Decodable {
        let data: [Item]

        struct Item: Decodable {
            let id: String
            let displayName: String?
            let inputModalities: [String]?
            let outputModalities: [String]?

            private enum CodingKeys: String, CodingKey {
                case id, modalities
                case displayName = "display_name"
            }

            private struct Modalities: Decodable {
                let input: [String]?
                let output: [String]?
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                id = try container.decode(String.self, forKey: .id)
                displayName = try? container.decodeIfPresent(String.self, forKey: .displayName)
                // Vendor extension: other servers may use a different shape.
                let modalities = try? container.decodeIfPresent(Modalities.self, forKey: .modalities)
                inputModalities = modalities?.input
                outputModalities = modalities?.output
            }
        }
    }

    // MARK: - Requests

    func makeChatRequest() throws -> URLRequest {
        guard let configuration else { throw CustomEndpointError.notConfigured }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        Self.applyToken(token ?? "", to: &request)
        return request
    }

    /// The cloud Worker takes the model from the URL; OpenAI-compatible servers require it in the body.
    static func requestBody(_ body: Data, for model: ModelConfig) throws -> Data {
        guard model.isCustomEndpoint,
              var object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            return body
        }
        object["model"] = model.upstreamID
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func applyToken(_ token: String, to request: inout URLRequest) {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}
