//
//  OnboardingScenario.swift
//  ShareCore
//

import Foundation

/// A translation scenario the user can pick on the first-run scenario page.
public enum OnboardingScenario: String, CaseIterable, Identifiable, Sendable {
    /// Words and selected text, translated from the system text menu.
    case words
    /// Live speech picked up by the microphone.
    case liveConversations
    /// Audio playing on the iPhone, captured through the broadcast extension.
    case showsAndVideos

    public var id: String {
        rawValue
    }
}

/// The audio input a Realtime onboarding step walks the user through.
public enum OnboardingRealtimeInput: Equatable, Sendable {
    case microphone
    case iphoneAudio
}

/// The onboarding flows a set of picked scenarios needs, and the order they run in.
public struct OnboardingRoute: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case realtime
        case words
    }

    public let scenarios: Set<OnboardingScenario>

    /// An empty selection (the user skipped the picker) keeps the original words-only flow.
    public init(scenarios: Set<OnboardingScenario>) {
        self.scenarios = scenarios.isEmpty ? [.words] : scenarios
    }

    public var includesWords: Bool {
        scenarios.contains(.words)
    }

    /// The inputs to try, microphone before iPhone Audio. Empty when Realtime is not picked.
    public var realtimeInputs: [OnboardingRealtimeInput] {
        var inputs: [OnboardingRealtimeInput] = []
        if scenarios.contains(.liveConversations) {
            inputs.append(.microphone)
        }
        if scenarios.contains(.showsAndVideos) {
            inputs.append(.iphoneAudio)
        }
        return inputs
    }

    public var includesRealtime: Bool {
        !realtimeInputs.isEmpty
    }

    /// Realtime runs first because the words flow ends with the premium trial and paywall.
    public var phases: [Phase] {
        var phases: [Phase] = []
        if includesRealtime {
            phases.append(.realtime)
        }
        if includesWords {
            phases.append(.words)
        }
        return phases
    }

    /// Only the words flow closes with its own premium offer; without it the first-run paywall follows.
    public var endsWithFirstRunPaywall: Bool {
        !includesWords
    }
}
