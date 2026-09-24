//
//  VoiceConfig.swift
//  ShareCore
//
//  Created by AI Assistant on 2025/02/02.
//

import Foundation

/// Represents a single voice available for TTS
public struct VoiceConfig: Identifiable, Hashable, Codable, Sendable {
    /// Unique voice identifier (e.g., "alloy")
    public let id: String

    /// Human-readable display name (e.g., "Alloy")
    public let name: String

    /// Whether this voice is the default selection
    public let isDefault: Bool

    public init(id: String, name: String, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.isDefault = isDefault
    }
}

// MARK: - Default Voices

public extension VoiceConfig {
    /// Voices offered by the TTS voice picker
    static let defaultVoices: [VoiceConfig] = [
        VoiceConfig(id: "alloy", name: "Alloy", isDefault: true),
        VoiceConfig(id: "ash", name: "Ash"),
        VoiceConfig(id: "coral", name: "Coral"),
        VoiceConfig(id: "echo", name: "Echo"),
        VoiceConfig(id: "fable", name: "Fable"),
        VoiceConfig(id: "nova", name: "Nova"),
        VoiceConfig(id: "onyx", name: "Onyx"),
        VoiceConfig(id: "sage", name: "Sage"),
        VoiceConfig(id: "shimmer", name: "Shimmer"),
    ]

    /// Default voice ID
    static let defaultVoiceID = "alloy"
}
