//
//  ModelConfig.swift
//  ShareCore
//
//  Created by Codex on 2025/01/27.
//

import Foundation

public struct ModelTagStyle: Hashable, Codable, Sendable {
    public let textColor: String?
    public let backgroundColor: String?

    public init(textColor: String? = nil, backgroundColor: String? = nil) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }
}

/// Represents a single model available from the cloud API
public struct ModelConfig: Identifiable, Hashable, Codable, Sendable {
    /// Unique model identifier (e.g., "gpt-4.1-nano")
    public let id: String

    /// Human-readable display name (e.g., "GPT-4.1 Nano")
    public let displayName: String

    /// Whether this model is the default selection
    public let isDefault: Bool

    /// Whether this model requires a premium subscription
    public let isPremium: Bool

    /// Whether this model supports vision (image input)
    public let supportsVision: Bool

    /// Optional tags from server (e.g., "latest")
    public let tags: [String]

    public let tagStyles: [String: ModelTagStyle]

    /// Whether this model is hidden by default (collapsed in UI)
    public let hidden: Bool

    private enum CodingKeys: String, CodingKey {
        case id, displayName, isDefault, isPremium, supportsVision, tags, tagStyles, hidden
    }

    public init(
        id: String,
        displayName: String,
        isDefault: Bool = false,
        isPremium: Bool = false,
        supportsVision: Bool = true,
        tags: [String] = [],
        tagStyles: [String: ModelTagStyle] = [:],
        hidden: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.isDefault = isDefault
        self.isPremium = isPremium
        self.supportsVision = supportsVision
        self.tags = tags
        self.tagStyles = tagStyles
        self.hidden = hidden
    }

    /// Well-known identifier for the on-device Apple Translate model.
    public static let appleTranslateID = "apple-translate"

    /// Well-known identifier for the free Google Translate model.
    public static let googleTranslateID = "google-translate"
    public static let microsoftTranslateID = "microsoft-translate"

    /// Well-known identifier for the free GPT-5 Nano model.
    public static let nanoModelID = "gpt-5-nano"

    /// Well-known identifier for the on-device Apple Foundation Model.
    public static let foundationModelID = "apple-foundation-model"

    /// Well-known identifier for Apple Private Cloud Compute.
    public static let privateCloudModelID = "apple-private-cloud"

    /// Pre-built ModelConfig for Apple Translate.
    public static let appleTranslate = ModelConfig(
        id: appleTranslateID,
        displayName: "Apple Translate",
        isDefault: false,
        isPremium: false,
        supportsVision: false,
        tags: ["on-device"],
        hidden: false
    )

    /// Pre-built ModelConfig for Google Translate.
    public static let googleTranslate = ModelConfig(
        id: googleTranslateID,
        displayName: "Google Translate",
        isDefault: false,
        isPremium: false,
        supportsVision: false,
        tags: ["free"],
        hidden: false
    )

    public static let microsoftTranslate = ModelConfig(
        id: microsoftTranslateID,
        displayName: String(localized: "Microsoft Translate"),
        supportsVision: false
    )

    /// Pre-built ModelConfig for GPT-5 Nano.
    public static let nanoModel = ModelConfig(
        id: nanoModelID,
        displayName: "GPT-5 Nano",
        isDefault: true,
        isPremium: false
    )

    /// Pre-built ModelConfig for Apple Foundation Model.
    public static let foundationModel = ModelConfig(
        id: foundationModelID,
        displayName: "Apple Foundation Model",
        isDefault: false,
        isPremium: false,
        supportsVision: false,
        tags: ["on-device"],
        hidden: false
    )

    /// Pre-built ModelConfig for Apple Private Cloud Compute.
    public static let privateCloudModel = ModelConfig(
        id: privateCloudModelID,
        displayName: "Apple Private Cloud",
        isDefault: false,
        isPremium: false,
        supportsVision: false,
        tags: ["private-cloud"],
        hidden: false
    )

    public static var appleIntelligenceModels: [ModelConfig] {
        BuildEnvironment.isDirectDistribution ? [foundationModel] : [foundationModel, privateCloudModel]
    }

    /// Built-in direct translation services, in display order. Apple Translate is
    /// included only when the platform supports it.
    public static var translationServices: [ModelConfig] {
        var services = [googleTranslate, microsoftTranslate]
        if AppleTranslationService.shared.isAvailable {
            services.insert(appleTranslate, at: 0)
        }
        return services
    }

    /// Whether this model runs locally on-device.
    public var isLocal: Bool { id == Self.appleTranslateID || id == Self.foundationModelID }

    /// Whether this is a non-LLM direct translation service.
    public var isDirectTranslation: Bool { Self.isDirectTranslationID(id) }

    /// Whether this model is Google Translate.
    public var isGoogleTranslate: Bool { id == Self.googleTranslateID }

    /// Whether this model uses an Apple Foundation Model.
    public var isFoundationModel: Bool { Self.isFoundationModelID(id) }

    /// Whether this model uses Apple Private Cloud Compute.
    public var isPrivateCloudModel: Bool { id == Self.privateCloudModelID }

    /// Whether this model is executed through the cloud Worker.
    public var isCloudModel: Bool { !isDirectTranslation && !isFoundationModel }

    /// Whether the given model ID refers to a non-LLM direct translation service.
    public static func isDirectTranslationID(_ id: String) -> Bool {
        id == appleTranslateID || id == googleTranslateID || id == microsoftTranslateID
    }

    /// Whether the given model ID refers to an Apple Foundation Model.
    public static func isFoundationModelID(_ id: String) -> Bool {
        id == foundationModelID || id == privateCloudModelID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        isPremium = try container.decode(Bool.self, forKey: .isPremium)
        supportsVision = try container.decodeIfPresent(Bool.self, forKey: .supportsVision) ?? true
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        // Styling is cosmetic: malformed metadata must not hide the model list.
        tagStyles = (try? container.decode([String: ModelTagStyle].self, forKey: .tagStyles)) ?? [:]
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }
}

/// Response from /models API endpoint
public struct ModelsResponse: Codable, Sendable {
    public let models: [ModelConfig]

    public init(models: [ModelConfig]) {
        self.models = models
    }
}

// MARK: - Cloud Service Constants

public enum CloudServiceConstants {
    /// Cloud service endpoint (Cloudflare Worker)
    public static var endpoint: URL { AppSecrets.cloudEndpoint }

    /// Shared secret for HMAC signing
    public static var secret: String { AppSecrets.cloudSecret }

    /// API version parameter
    public static let apiVersion = AppSecrets.cloudAPIVersion
}
