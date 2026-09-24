import XCTest

@MainActor
final class TLingoScreenshots: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS)
            XCUIDevice.shared.press(.home)
        #endif
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    func test01MultiModelTranslation() {
        launchSnapshot(fixture: "multi-model-translation")
        assertHomeLocalized()
        snapshot("01_MultiModelTranslation")
    }

    func test02TranslateAnywhere() {
        launchSnapshot(
            fixture: "multi-model-translation",
            additionalArguments: ["-SNAPSHOT_EXTENSION_PREVIEW"]
        )
        assertExtensionLocalized()
        snapshot("02_TranslateAnywhere")
    }

    func test03OfflineRealtimeTranslation() {
        launchSnapshot(fixture: "realtime-bilingual-live", tab: "realtime")
        assertRealtimeLocalized()
        app.buttons["realtime_options_button"].tap()
        sleep(1)
        snapshot("03_OfflineRealtime")
    }

    func test04BilingualCaptions() {
        launchSnapshot(fixture: "realtime-bilingual-live", tab: "realtime")
        assertRealtimeLocalized()
        snapshot("04_BilingualCaptions")
    }

    func test05WritingTools() {
        launchSnapshot(fixture: "multi-model-translation", action: "polish")
        assertHomeLocalized()
        snapshot("05_WritingTools")
    }

    func test06GrammarCheck() {
        launchSnapshot(fixture: "multi-model-translation", action: "grammar")
        assertHomeLocalized()
        snapshot("06_GrammarCheck")
    }

    func test07CustomActions() {
        launchSnapshot(fixture: "multi-model-translation")
        assertHomeLocalized()
        app.buttons["home_manage_actions_button"].tap()
        sleep(1)
        snapshot("07_CustomActions")
    }

    func testNativeHomeToolbarNavigation() {
        launchSnapshot(fixture: "multi-model-translation")
        let history = app.navigationBars.buttons["home_history_button"]
        XCTAssertTrue(history.waitForExistence(timeout: 8))
        app.swipeUp()
        XCTAssertTrue(history.isHittable)
        let chat = app.buttons["tab_chat"]
        XCTAssertTrue(chat.isHittable)
        chat.tap()
        XCTAssertTrue(app.navigationBars.buttons["chat_history_button"].waitForExistence(timeout: 5))
        snapshot("08_NativeChatToolbar")
        let chatBar = app.navigationBars.firstMatch
        chatBar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        history.tap()
        XCTAssertTrue(app.navigationBars.buttons.firstMatch.waitForExistence(timeout: 5))
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        snapshot("09_NativeHomeToolbar")
    }

    func testNativeRealtimeToolbar() {
        launchSnapshot(fixture: "realtime-bilingual-live", tab: "realtime")
        let options = app.navigationBars.buttons["realtime_options_button"]
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        XCTAssertTrue(app.navigationBars.buttons["realtime_start_button"].isHittable)
        XCTAssertTrue(app.buttons["tab_chat"].isHittable)
        snapshot("10_NativeRealtimeToolbar")
        let optionsTitle = options.label
        options.tap()
        XCTAssertTrue(app.navigationBars[optionsTitle].waitForExistence(timeout: 5))
        snapshot("11_NativeRealtimeOptions")
    }

    private func launchSnapshot(
        fixture: String,
        tab: String? = nil,
        action: String? = nil,
        additionalArguments: [String] = []
    ) {
        setupSnapshot(app)
        app.launchArguments.append("-FASTLANE_SNAPSHOT")
        app.launchArguments.append(contentsOf: ["-SNAPSHOT_FIXTURE", fixture])
        app.launchArguments.append(contentsOf: ["-SNAPSHOT_LOCALE", snapshotLanguageID])
        if let tab {
            app.launchArguments.append(contentsOf: ["-SNAPSHOT_TAB", tab])
        }
        if let action {
            app.launchArguments.append(contentsOf: ["-SNAPSHOT_ACTION", action])
        }
        app.launchArguments.append(contentsOf: additionalArguments)
        app.launch()
    }

    private func assertHomeLocalized() {
        let expected = localizedHomeModelLabel
        let modelPicker = app.buttons["home_model_picker"]
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 8))
        XCTAssertEqual(modelPicker.label, expected)
    }

    private func assertExtensionLocalized() {
        let expected = localizedExtensionTitle
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 8))
    }

    private func assertRealtimeLocalized() {
        let expected = localizedRealtimeTitle
        XCTAssertTrue(app.staticTexts[expected].waitForExistence(timeout: 8))
    }

    private var snapshotLanguageID: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh-Hant") || preferred.contains("TW") { return "zh-Hant" }
        if preferred.hasPrefix("zh") { return "zh-Hans" }
        if preferred.hasPrefix("de") { return "de-DE" }
        if preferred.hasPrefix("fr") { return "fr-FR" }
        if preferred.hasPrefix("es") { return "es-ES" }
        if preferred.hasPrefix("pt") { return "pt-BR" }
        if preferred.hasPrefix("ar") { return "ar-SA" }
        if preferred.hasPrefix("nb") { return "no" }
        if preferred.hasPrefix("nl") { return "nl-NL" }
        if preferred.hasPrefix("en") { return "en-US" }
        return preferred.split(separator: "-").first.map(String.init) ?? "en-US"
    }

    private var localizedHomeModelLabel: String {
        switch snapshotLanguageID {
        case "zh-Hans", "zh-Hant": return "模型"
        case "ja": return "モデル"
        case "ko": return "모델"
        case "de-DE": return "Modelle"
        case "fr-FR": return "Modèles"
        case "es-ES": return "Modelos"
        case "it": return "Modelli"
        case "pt-BR": return "Modelos"
        case "ar-SA": return "النماذج"
        case "da", "no", "sv", "tr": return "Modeller"
        case "nl-NL": return "Modellen"
        case "id": return "Model"
        default: return "Models"
        }
    }

    private var localizedExtensionTitle: String {
        switch snapshotLanguageID {
        case "zh-Hans": return "使用 TLingo 翻译"
        case "zh-Hant": return "使用 TLingo 翻譯"
        case "ja": return "TLingoで翻訳"
        case "ko": return "TLingo로 번역"
        case "de-DE": return "Mit TLingo übersetzen"
        case "fr-FR": return "Traduire avec TLingo"
        case "es-ES": return "Traducir con TLingo"
        case "it": return "Traduci con TLingo"
        case "pt-BR": return "Traduzir com TLingo"
        case "ar-SA": return "الترجمة باستخدام TLingo"
        case "da": return "Oversæt med TLingo"
        case "no": return "Oversett med TLingo"
        case "nl-NL": return "Vertalen met TLingo"
        case "sv": return "Översätt med TLingo"
        case "tr": return "TLingo ile çevir"
        case "id": return "Terjemahkan dengan TLingo"
        default: return "Translate with TLingo"
        }
    }

    private var localizedRealtimeTitle: String {
        switch snapshotLanguageID {
        case "zh-Hans": return "实时"
        case "zh-Hant": return "即時"
        case "ja": return "リアルタイム"
        case "ko": return "실시간"
        case "de-DE": return "Echtzeit"
        case "fr-FR": return "Temps réel"
        case "es-ES": return "En tiempo real"
        case "it": return "In tempo reale"
        case "pt-BR": return "Em tempo real"
        case "ar-SA": return "في الوقت الحقيقي"
        case "da": return "Realtid"
        case "no": return "Sanntid"
        case "nl-NL": return "Realtime"
        case "sv": return "Realtid"
        case "tr": return "Gerçek zamanlı"
        case "id": return "Waktu nyata"
        default: return "Realtime"
        }
    }

    private func setupSnapshot(_ app: XCUIApplication) {
        let cacheDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/tools.fastlane", isDirectory: true)
        let language = ProcessInfo.processInfo.environment["SNAPSHOT_APPLE_LANGUAGE"]
        let locale = ProcessInfo.processInfo.environment["SNAPSHOT_APPLE_LOCALE"]
        let snapshotLocale = ProcessInfo.processInfo.environment["SNAPSHOT_LOCALE"]
        let extraArguments = readLaunchArguments(from: cacheDirectory.appendingPathComponent("snapshot-launch_arguments.txt"))

        if let language {
            app.launchArguments.append(contentsOf: ["-AppleLanguages", "(\(language))"])
        }
        if let locale {
            app.launchArguments.append(contentsOf: ["-AppleLocale", locale])
        }
        if let snapshotLocale {
            app.launchArguments.append(contentsOf: ["-SNAPSHOT_LOCALE", snapshotLocale])
        }
        app.launchArguments.append(contentsOf: extraArguments)
    }

    private func snapshot(_ name: String) {
        let screenshotsDirectory = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Caches/tools.fastlane/screenshots", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)
            let deviceName = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "Simulator"
            let url = screenshotsDirectory.appendingPathComponent("\(deviceName)-\(name).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: url, options: .atomic)
        } catch {
            XCTFail("Failed to save snapshot \(name): \(error)")
        }
    }

    private func readLaunchArguments(from url: URL) -> [String] {
        guard let value = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let arguments = value
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        return arguments
    }
}
