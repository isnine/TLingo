//
//  OnboardingPracticePhrase.swift
//  ShareCore
//

import Foundation

/// A short sentence the Realtime onboarding asks the user to say, in the language they picked to speak.
public enum OnboardingPracticePhrase {
    private static let phrases: [String: String] = [
        "en": "Could you tell me how to get to the station?",
        "zh-Hans": "请问去车站怎么走？",
        "zh-Hant": "請問去車站怎麼走？",
        "ja": "駅への行き方を教えてもらえますか？",
        "ko": "역에 어떻게 가는지 알려 주시겠어요?",
        "es": "¿Puede decirme cómo llegar a la estación?",
        "fr": "Pouvez-vous m'indiquer comment aller à la gare ?",
        "de": "Können Sie mir sagen, wie ich zum Bahnhof komme?",
        "pt-BR": "Você pode me dizer como chegar à estação?",
        "it": "Può dirmi come arrivare alla stazione?",
        "ru": "Подскажите, как пройти к вокзалу?",
    ]

    /// The exact language code wins (`zh-Hant`), then its base language (`en-GB` → `en`).
    /// Returns nil when there is no sentence, so callers can fall back to a free prompt.
    public static func phrase(for language: SourceLanguageOption) -> String? {
        let code = language.rawValue
        if let exact = phrases[code] {
            return exact
        }
        let base = code.split(separator: "-").first.map(String.init) ?? code
        return phrases[base]
    }
}
