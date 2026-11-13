//
//  RealtimeTranslationSchedulingPolicy.swift
//  ShareCore
//

import Foundation

enum RealtimeTranslationSchedulingPolicy {
    static func cadenceInterval(for provider: RealtimeTranslationProvider) -> TimeInterval {
        switch provider {
        case .appleTranslator:
            return 0.5
        case .appleTranslationRealtime:
            return 0.35
        case .transcriptionOnly:
            return 0
        }
    }
}
