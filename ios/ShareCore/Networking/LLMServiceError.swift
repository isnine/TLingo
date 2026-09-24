//
//  LLMServiceError.swift
//  ShareCore
//
//  Created by Codex on 2025/10/19.
//

import Foundation

public enum LLMServiceError: LocalizedError {
    case emptyContent
    case httpError(statusCode: Int, body: String)
    case visionNotSupported(modelName: String)

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return String(localized: "No content returned from the model")
        case let .httpError(statusCode, body):
            return String(localized: "HTTP error \(statusCode): \(body)")
        case let .visionNotSupported(modelName):
            return String(localized: "\(modelName) does not support image input")
        }
    }
}
