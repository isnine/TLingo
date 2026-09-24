//
//  RealtimeTranslationSourceTracker.swift
//  ShareCore
//

import Foundation

struct RealtimeTranslationSourceTracker {
    private var scheduledSource = ""

    mutating func shouldSchedule(_ source: String) -> Bool {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            reset()
            return true
        }
        guard trimmed != scheduledSource else { return false }

        scheduledSource = trimmed
        return true
    }

    mutating func reset() {
        scheduledSource = ""
    }
}
