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
    case trialUnavailable

    public var errorDescription: String? {
        switch self {
        case .emptyContent:
            return String(localized: "No content returned from the model")
        case let .httpError(statusCode, body):
            switch Self.serverErrorCode(in: body) {
            case "trial_exhausted":
                return String(localized: "You've used all free trial requests on this device. Upgrade to Premium to keep using premium models.")
            case "trial_not_registered", "trial_unavailable":
                return Self.trialUnavailableDescription
            default:
                return String(localized: "HTTP error \(statusCode): \(body)")
            }
        case .trialUnavailable:
            return Self.trialUnavailableDescription
        case let .visionNotSupported(modelName):
            return String(localized: "\(modelName) does not support image input")
        }
    }

    private static var trialUnavailableDescription: String {
        String(localized: "The free trial isn't available on this device right now. Please try again later.")
    }

    /// The Worker's JSON error code, e.g. `{"error":"trial_exhausted"}`.
    private static func serverErrorCode(in body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["error"] as? String
    }
}
