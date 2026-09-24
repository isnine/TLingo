//
//  LLMRequestPayload.swift
//  ShareCore
//
//  Created by Codex on 2025/10/19.
//

import Foundation

public struct LLMRequestPayload: Encodable {
    public struct Message: Encodable {
        public let role: String
        /// For text-only messages, this is a plain string.
        /// For multimodal messages (text + images), this is an array of content parts.
        private let contentValue: ContentValue

        enum ContentValue {
            case text(String)
            case parts([ContentPart])
        }

        /// Convenience accessor — returns the text content (first text part for multimodal).
        public var textContent: String {
            switch contentValue {
            case let .text(str):
                return str
            case let .parts(parts):
                return parts.compactMap { part in
                    if case let .text(t) = part { return t }
                    return nil
                }.joined()
            }
        }

        public var containsImages: Bool {
            if case let .parts(parts) = contentValue {
                return parts.contains {
                    if case .imageURL = $0 { return true }
                    return false
                }
            }
            return false
        }

        // MARK: - Content Parts

        public enum ContentPart {
            case text(String)
            case imageURL(String) // base64 data URL
        }

        // MARK: - Initializers

        /// Text-only message (backward compatible)
        public init(role: String, content: String) {
            self.role = role
            contentValue = .text(content)
        }

        /// Multimodal message with text + images
        public init(role: String, text: String, imageDataURLs: [String]) {
            self.role = role
            if imageDataURLs.isEmpty {
                contentValue = .text(text)
            } else {
                var parts: [ContentPart] = [.text(text)]
                for url in imageDataURLs {
                    parts.append(.imageURL(url))
                }
                contentValue = .parts(parts)
            }
        }

        // MARK: - Encodable

        private enum CodingKeys: String, CodingKey {
            case role, content
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(role, forKey: .role)

            switch contentValue {
            case let .text(str):
                try container.encode(str, forKey: .content)
            case let .parts(parts):
                var partsContainer = container.nestedUnkeyedContainer(forKey: .content)
                for part in parts {
                    switch part {
                    case let .text(text):
                        try partsContainer.encode(TextPart(type: "text", text: text))
                    case let .imageURL(url):
                        try partsContainer.encode(ImageURLPart(
                            type: "image_url",
                            image_url: ImageURLPart.ImageURL(url: url)
                        ))
                    }
                }
            }
        }

        // MARK: - Encoding helpers

        private struct TextPart: Encodable {
            let type: String
            let text: String
        }

        private struct ImageURLPart: Encodable {
            let type: String
            let image_url: ImageURL

            struct ImageURL: Encodable {
                let url: String
            }
        }

        /// Builds a `[String: Any]` dictionary for use with JSONSerialization (e.g. structured output).
        /// Avoids the round-trip of JSONEncoder → JSONSerialization.jsonObject.
        func toDictionary() -> [String: Any] {
            switch contentValue {
            case let .text(str):
                return ["role": role, "content": str]
            case let .parts(parts):
                let partsArray: [[String: Any]] = parts.map { part in
                    switch part {
                    case let .text(text):
                        return ["type": "text", "text": text]
                    case let .imageURL(url):
                        return ["type": "image_url", "image_url": ["url": url]]
                    }
                }
                return ["role": role, "content": partsArray]
            }
        }
    }

    public let messages: [Message]
    public let stream: Bool?
    public let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case messages
        case stream
        case reasoningEffort = "reasoning_effort"
    }

    public init(messages: [Message], stream: Bool? = nil, reasoningEffort: String? = nil) {
        self.messages = messages
        self.stream = stream
        self.reasoningEffort = reasoningEffort
    }
}
