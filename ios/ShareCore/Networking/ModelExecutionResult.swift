//
//  ModelExecutionResult.swift
//  ShareCore
//
//  Created by Codex on 2025/01/27.
//

import Foundation

public struct ModelExecutionResult {
    public let modelID: String
    public let duration: TimeInterval
    public let response: Result<String, Error>
    public let diffSource: String?
    public let supplementalTexts: [String]
    public let sentencePairs: [SentencePair]
    public let suggestedActions: [String]

    // Optional network timing breakdown (best-effort; may be unavailable).
    public let upstreamTTFB: TimeInterval?
    public let clientToAzureLatency: TimeInterval?
    public let networkMetrics: NetworkTimingMetrics?

    public init(
        modelID: String,
        duration: TimeInterval,
        response: Result<String, Error>,
        diffSource: String? = nil,
        supplementalTexts: [String] = [],
        sentencePairs: [SentencePair] = [],
        suggestedActions: [String] = [],
        upstreamTTFB: TimeInterval? = nil,
        clientToAzureLatency: TimeInterval? = nil,
        networkMetrics: NetworkTimingMetrics? = nil
    ) {
        self.modelID = modelID
        self.duration = duration
        self.response = response
        self.diffSource = diffSource
        self.supplementalTexts = supplementalTexts
        self.sentencePairs = sentencePairs
        self.suggestedActions = suggestedActions
        self.upstreamTTFB = upstreamTTFB
        self.clientToAzureLatency = clientToAzureLatency
        self.networkMetrics = networkMetrics
    }
}
