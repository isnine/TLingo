//
//  TranslationProvider.swift
//  TranslationUI
//
//  Created by Zander Wang on 2025/10/18.
//

import ExtensionKit
import Foundation
import os
import ShareCore
import SwiftUI
import TranslationUIProvider

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "Extension")

@main
final class TranslationProviderExtension: TranslationUIProviderExtension {
    required init() {
        UserDefaults.standard.addSuite(named: AppPreferences.appGroupSuiteName)
        AppPreferences.shared.refreshFromDefaults()
        logger.debug("init — configDir: \(ConfigurationFileManager.shared.configurationsDirectory.path, privacy: .public)")
    }

    var body: some TranslationUIProviderExtensionScene {
        TranslationUIProviderSelectedTextScene { context in
            ExtensionCompactView(context: context)
        }
    }
}
