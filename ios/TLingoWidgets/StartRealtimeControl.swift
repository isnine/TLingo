//
//  StartRealtimeControl.swift
//  TLingoWidgets
//

import AppIntents
import SwiftUI
import WidgetKit

struct StartRealtimeControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.zanderwang.AITranslator.StartRealtime") {
            ControlWidgetButton(action: StartRealtimeTranslationIntent()) {
                Label("Realtime Translation", systemImage: "waveform")
            }
        }
        .displayName("Realtime Translation")
        .description("Start realtime translation in TLingo.")
    }
}
