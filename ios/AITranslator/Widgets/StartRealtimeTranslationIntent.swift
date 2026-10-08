//
//  StartRealtimeTranslationIntent.swift
//  TLingo
//
//  Compiled into both the TLingo app and TLingoWidgets so controls and Shortcuts can run it in the app.
//

#if os(iOS)
    import AppIntents
    import Foundation

    struct StartRealtimeTranslationIntent: AppIntent {
        static let title: LocalizedStringResource = "Start Realtime Translation"
        static let description = IntentDescription("Opens TLingo and starts realtime translation.")
        static let supportedModes: IntentModes = .foreground

        func perform() async throws -> some IntentResult & OpensIntent {
            // The app's deep link handler owns session setup, permissions and paywall checks.
            .result(opensIntent: OpenURLIntent(URL(string: "tlingo://realtime")!))
        }
    }
#endif
