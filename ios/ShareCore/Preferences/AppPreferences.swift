//
//  AppPreferences.swift
//  ShareCore
//
//  Created by Codex on 2025/10/27.
//

import Combine
import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "Preferences")

public final class AppPreferences: ObservableObject {
    public static let appGroupSuiteName = "group.com.zanderwang.AITranslator"
    private static let sharedDefaultsInstance: UserDefaults = AppPreferences.resolveSharedDefaults()

    public static var sharedDefaults: UserDefaults {
        sharedDefaultsInstance
    }

    public static let shared = AppPreferences()

    @Published public private(set) var targetLanguage: TargetLanguageOption
    @Published public private(set) var sourceLanguage: SourceLanguageOption
    @Published public private(set) var currentConfigName: String?
    @Published public private(set) var useICloudForConfig: Bool
    @Published public private(set) var voiceActionHintDismissed: Bool
    @Published public private(set) var enabledModelIDs: Set<String>
    @Published public private(set) var modelResultOrder: ModelResultOrder
    @Published public private(set) var chatModelID: String?
    @Published public private(set) var selectedVoiceID: String
    @Published public private(set) var isPremium: Bool
    @Published public private(set) var hasAcceptedDataSharing: Bool
    @Published public private(set) var hasSeenIOSPaywallOnboarding: Bool
    @Published public private(set) var hasSeenDefaultTranslationOnboarding: Bool
    @Published public private(set) var hasCompletedDefaultTranslationTrial: Bool
    @Published public private(set) var lastDefaultTranslationTrialAt: Date?
    @Published public private(set) var accentTheme: AccentTheme
    @Published public private(set) var appleTranslateInstalledLanguages: Set<String>
    #if os(macOS)
        @Published public private(set) var hasCompletedOnboarding: Bool
        @Published public private(set) var lastCompletedOnboardingVersion: String?
        // Always present in ShareCore (framework is compiled once). Gated at
        // the UI layer (#if DIRECT_DISTRIBUTION) so App Store builds
        // hide the toggle but the storage path stays consistent.
        @Published public private(set) var textSelectionTranslationEnabled: Bool
        /// User-resizable height for the menu bar quick translate popover.
        /// Height defaults to 420pt and can grow up to 80% of the active
        /// screen's visible height via the bottom drag handle in
        /// `MenuBarPopoverView`.
        @Published public private(set) var menuBarPopoverHeight: CGFloat
        public static let menuBarPopoverDefaultHeight: CGFloat = 420
        public static let menuBarPopoverMinHeight: CGFloat = 420

        /// User-resizable width for the menu bar quick translate popover.
        /// Width defaults to 360pt and can grow up to 80% of the active
        /// screen's visible width via the right-edge drag handle in
        /// `MenuBarPopoverView`.
        @Published public private(set) var menuBarPopoverWidth: CGFloat
        public static let menuBarPopoverDefaultWidth: CGFloat = 360
        public static let menuBarPopoverMinWidth: CGFloat = 360

        /// User-resizable size for the accessibility text-selection
        /// translation popup. Persisted so each new selection reuses the
        /// last size instead of resetting to the default.
        @Published public private(set) var selectionPopupWidth: CGFloat
        @Published public private(set) var selectionPopupHeight: CGFloat
        /// Last user-selected origin for the accessibility text-selection popup.
        @Published public private(set) var selectionPopupOrigin: CGPoint?
        public static let selectionPopupDefaultSize = CGSize(width: 400, height: 320)
        public static let selectionPopupMinSize = CGSize(width: 320, height: 200)
        public static let selectionPopupMaxSize = CGSize(width: 900, height: 800)
        @Published public private(set) var realtimeCaptionWindowMode: RealtimeCaptionWindowMode
        @Published public private(set) var realtimeCaptionPrivacyModeEnabled: Bool
    #endif

    #if os(macOS) || os(iOS)
        @Published public private(set) var realtimeTargetLanguage: TargetLanguageOption
        @Published public private(set) var realtimeSourceLanguage: SourceLanguageOption
        @Published public private(set) var realtimeTranslationProvider: RealtimeTranslationProvider
        @Published public private(set) var realtimeRecognitionEngine: RealtimeRecognitionEngine
        @Published public private(set) var realtimeRecognitionModelID: String
        @Published public private(set) var realtimeShowCaptions: Bool
        @Published public private(set) var realtimeDualInputHistoryRecordingEnabled: Bool
    #endif

    private let defaults: UserDefaults
    private var notificationObserver: NSObjectProtocol?
    private var isRefreshing = false

    init(
        defaults: UserDefaults = AppPreferences.resolveSharedDefaults(),
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults

        #if os(macOS) || os(iOS)
            RetiredRealtimeAzureMigration.cleanup(defaults: defaults)
        #endif

        // Direct distribution: clear App-Store-only premium flags that may
        // have been left in defaults by a prior App Store install at the same
        // Bundle ID. Direct's premium state lives in WebEntitlementProvider.
        //
        // We deliberately DO NOT touch `entitlement.web.*` keys here — those
        // belong to WebEntitlementProvider and represent legitimate Pro state
        // for signed-in users (the offline-grace cache). The provider's own
        // `hydrateFromCache()` already refuses cached `isPro=true` when no
        // Supabase session is present, so unauthenticated stale caches are
        // already covered without us purging signed-in users on every launch.
        if BuildEnvironment.isDirectDistribution {
            let staleAppGroupIsPremium = defaults.object(forKey: StorageKeys.isPremium) != nil
            let staleTFOverride = defaults.object(forKey: "testflight_premium_override") != nil

            if staleAppGroupIsPremium || staleTFOverride {
                logger.info(
                    """
                    Direct init – purging stale App Store premium keys: \
                    appGroup.isPremium=\(staleAppGroupIsPremium, privacy: .public) \
                    appGroup.tfOverride=\(staleTFOverride, privacy: .public)
                    """
                )
                defaults.removeObject(forKey: StorageKeys.isPremium)
                defaults.removeObject(forKey: "testflight_premium_override")
            }
        }

        targetLanguage = AppPreferences.readTargetLanguage(from: defaults)
        sourceLanguage = AppPreferences.readSourceLanguage(from: defaults)
        currentConfigName = defaults.string(forKey: StorageKeys.currentConfigName)
        useICloudForConfig = defaults.bool(forKey: StorageKeys.useICloudForConfig)
        voiceActionHintDismissed = defaults.bool(forKey: StorageKeys.voiceActionHintDismissed)
        enabledModelIDs = AppPreferences.readEnabledModelIDs(from: defaults)
        modelResultOrder = AppPreferences.readModelResultOrder(from: defaults)
        chatModelID = defaults.string(forKey: StorageKeys.chatModelID)
        selectedVoiceID = defaults.string(forKey: StorageKeys.selectedVoiceID) ?? VoiceConfig.defaultVoiceID
        isPremium = defaults.bool(forKey: StorageKeys.isPremium)
        hasAcceptedDataSharing = defaults.bool(forKey: StorageKeys.hasAcceptedDataSharing)
        hasSeenIOSPaywallOnboarding = defaults.bool(forKey: StorageKeys.hasSeenIOSPaywallOnboarding)
        hasSeenDefaultTranslationOnboarding = defaults.bool(forKey: StorageKeys.hasSeenDefaultTranslationOnboarding)
        hasCompletedDefaultTranslationTrial = defaults.bool(forKey: StorageKeys.hasCompletedDefaultTranslationTrial)
        lastDefaultTranslationTrialAt = defaults.object(forKey: StorageKeys.lastDefaultTranslationTrialAt) as? Date
        accentTheme = AppPreferences.readAccentTheme(from: defaults)
        appleTranslateInstalledLanguages = AppPreferences.readInstalledLanguages(from: defaults)

        // Clean up stale custom directory bookmark data from previous versions
        defaults.removeObject(forKey: "custom_config_directory")

        #if os(macOS)
            hasCompletedOnboarding = defaults.bool(forKey: StorageKeys.hasCompletedOnboarding)
            lastCompletedOnboardingVersion = defaults.string(forKey: StorageKeys.lastCompletedOnboardingVersion)
            textSelectionTranslationEnabled = defaults.bool(forKey: StorageKeys.textSelectionTranslationEnabled)
            menuBarPopoverHeight = AppPreferences.readMenuBarPopoverHeight(from: defaults)
            menuBarPopoverWidth = AppPreferences.readMenuBarPopoverWidth(from: defaults)
            let storedSelectionSize = AppPreferences.readSelectionPopupSize(from: defaults)
            selectionPopupWidth = storedSelectionSize.width
            selectionPopupHeight = storedSelectionSize.height
            selectionPopupOrigin = AppPreferences.readSelectionPopupOrigin(from: defaults)
            realtimeCaptionWindowMode = AppPreferences.readRealtimeCaptionWindowMode(from: defaults)
            realtimeCaptionPrivacyModeEnabled = AppPreferences.readRealtimeCaptionPrivacyModeEnabled(from: defaults)
        #endif

        #if os(macOS) || os(iOS)
            realtimeTargetLanguage = AppPreferences.readRealtimeTargetLanguage(
                from: defaults,
                preferredLanguages: preferredLanguages
            )
            realtimeSourceLanguage = AppPreferences.readRealtimeSourceLanguage(from: defaults)
            realtimeTranslationProvider = AppPreferences.readRealtimeTranslationProvider(from: defaults)
            realtimeRecognitionEngine = AppPreferences.readRealtimeRecognitionEngine(from: defaults)
            realtimeRecognitionModelID = AppPreferences.readRealtimeRecognitionModelID(from: defaults)
            realtimeShowCaptions = AppPreferences.readRealtimeShowCaptions(from: defaults)
            realtimeDualInputHistoryRecordingEnabled = defaults.bool(
                forKey: StorageKeys.realtimeDualInputHistoryRecordingEnabled
            )
        #endif

        notificationObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshFromDefaults()
            }
        }
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
    }

    public func setTargetLanguage(
        _ option: TargetLanguageOption,
        reason: String = "AppPreferences.setTargetLanguage"
    ) {
        guard targetLanguage != option else { return }

        let oldValue = targetLanguage.rawValue
        targetLanguage = option
        defaults.set(option.rawValue, forKey: TargetLanguageOption.storageKey)
        logLanguageChange(
            field: "targetLanguage",
            from: oldValue,
            to: option.rawValue,
            reason: reason
        )
    }

    public func setSourceLanguage(
        _ option: SourceLanguageOption,
        reason: String = "AppPreferences.setSourceLanguage"
    ) {
        guard sourceLanguage != option else { return }

        let oldValue = sourceLanguage.rawValue
        sourceLanguage = option
        defaults.set(option.rawValue, forKey: SourceLanguageOption.storageKey)
        logLanguageChange(
            field: "sourceLanguage",
            from: oldValue,
            to: option.rawValue,
            reason: reason
        )
    }

    public func setModelResultOrder(_ order: ModelResultOrder) {
        guard modelResultOrder != order else { return }
        modelResultOrder = order
        defaults.set(order.rawValue, forKey: StorageKeys.modelResultOrder)
    }

    private static func readModelResultOrder(from defaults: UserDefaults) -> ModelResultOrder {
        guard let stored = defaults.string(forKey: StorageKeys.modelResultOrder) else {
            return .firstCompletedFirst
        }
        guard let order = ModelResultOrder(rawValue: stored) else {
            logger.error("Invalid model result order: \(stored, privacy: .public)")
            return .firstCompletedFirst
        }
        return order
    }

    public func setCurrentConfigName(_ name: String?) {
        guard currentConfigName != name else { return }

        currentConfigName = name
        if let name {
            defaults.set(name, forKey: StorageKeys.currentConfigName)
        } else {
            defaults.removeObject(forKey: StorageKeys.currentConfigName)
        }
    }

    /// Updates the cached premium flag. Called by `WebEntitlementProvider`
    /// (Direct builds) when the Worker reports a fresh status, and by
    /// `StoreManager` (App Store builds) on transaction events.
    public func setIsPremium(_ value: Bool) {
        let currentIsPremium = isPremium
        guard currentIsPremium != value else { return }
        let isDirect = BuildEnvironment.isDirectDistribution
        logger.info(
            "setIsPremium \(currentIsPremium, privacy: .public)->\(value, privacy: .public) direct=\(isDirect, privacy: .public)"
        )
        isPremium = value
        defaults.set(value, forKey: StorageKeys.isPremium)
    }

    public func setVoiceActionHintDismissed(_ dismissed: Bool) {
        guard voiceActionHintDismissed != dismissed else { return }

        voiceActionHintDismissed = dismissed
        defaults.set(dismissed, forKey: StorageKeys.voiceActionHintDismissed)
    }

    public func setHasSeenIOSPaywallOnboarding(_ seen: Bool) {
        guard hasSeenIOSPaywallOnboarding != seen else { return }

        hasSeenIOSPaywallOnboarding = seen
        defaults.set(seen, forKey: StorageKeys.hasSeenIOSPaywallOnboarding)
    }

    public func setHasSeenDefaultTranslationOnboarding(_ seen: Bool) {
        guard hasSeenDefaultTranslationOnboarding != seen else { return }

        hasSeenDefaultTranslationOnboarding = seen
        defaults.set(seen, forKey: StorageKeys.hasSeenDefaultTranslationOnboarding)
    }

    public func recordDefaultTranslationTrialInvocation(date: Date = Date()) {
        hasCompletedDefaultTranslationTrial = true
        lastDefaultTranslationTrialAt = date
        defaults.set(true, forKey: StorageKeys.hasCompletedDefaultTranslationTrial)
        defaults.set(date, forKey: StorageKeys.lastDefaultTranslationTrialAt)
        // Wake the main app immediately. UserDefaults cross-process reads are
        // eventually consistent, so the onboarding view also needs the Darwin
        // notification to refresh on the next runloop instead of waiting for
        // its 1s poll tick.
        DefaultTranslationTrialNotifier.post()
    }

    #if os(macOS)
        public func setHasCompletedOnboarding(_ completed: Bool) {
            guard hasCompletedOnboarding != completed else { return }

            hasCompletedOnboarding = completed
            defaults.set(completed, forKey: StorageKeys.hasCompletedOnboarding)
        }

        public func setLastCompletedOnboardingVersion(_ version: String) {
            guard lastCompletedOnboardingVersion != version else { return }

            lastCompletedOnboardingVersion = version
            defaults.set(version, forKey: StorageKeys.lastCompletedOnboardingVersion)
        }

        public func setTextSelectionTranslationEnabled(_ enabled: Bool) {
            guard textSelectionTranslationEnabled != enabled else { return }

            textSelectionTranslationEnabled = enabled
            defaults.set(enabled, forKey: StorageKeys.textSelectionTranslationEnabled)
        }

        public func setMenuBarPopoverHeight(_ height: CGFloat, persist: Bool = true) {
            let clamped = max(AppPreferences.menuBarPopoverMinHeight, height.rounded())
            if menuBarPopoverHeight != clamped {
                menuBarPopoverHeight = clamped
            }
            if persist {
                defaults.set(Double(clamped), forKey: StorageKeys.menuBarPopoverHeight)
            }
        }

        public func setMenuBarPopoverWidth(_ width: CGFloat, persist: Bool = true) {
            let clamped = max(AppPreferences.menuBarPopoverMinWidth, width.rounded())
            if menuBarPopoverWidth != clamped {
                menuBarPopoverWidth = clamped
            }
            if persist {
                defaults.set(Double(clamped), forKey: StorageKeys.menuBarPopoverWidth)
            }
        }

        public var selectionPopupSize: CGSize {
            CGSize(width: selectionPopupWidth, height: selectionPopupHeight)
        }

        public func setSelectionPopupSize(_ size: CGSize) {
            let clamped = AppPreferences.clampSelectionPopupSize(size)
            let widthChanged = abs(selectionPopupWidth - clamped.width) > 0.5
            let heightChanged = abs(selectionPopupHeight - clamped.height) > 0.5
            guard widthChanged || heightChanged else { return }

            selectionPopupWidth = clamped.width
            selectionPopupHeight = clamped.height
            defaults.set(Double(clamped.width), forKey: StorageKeys.selectionPopupWidth)
            defaults.set(Double(clamped.height), forKey: StorageKeys.selectionPopupHeight)
        }

        public func setSelectionPopupOrigin(_ origin: CGPoint?) {
            guard selectionPopupOrigin != origin else { return }

            selectionPopupOrigin = origin
            if let origin {
                defaults.set(Double(origin.x), forKey: StorageKeys.selectionPopupOriginX)
                defaults.set(Double(origin.y), forKey: StorageKeys.selectionPopupOriginY)
            } else {
                defaults.removeObject(forKey: StorageKeys.selectionPopupOriginX)
                defaults.removeObject(forKey: StorageKeys.selectionPopupOriginY)
            }
        }

        public func setRealtimeCaptionWindowMode(_ mode: RealtimeCaptionWindowMode) {
            guard realtimeCaptionWindowMode != mode else { return }

            realtimeCaptionWindowMode = mode
            defaults.set(mode.rawValue, forKey: StorageKeys.realtimeCaptionWindowMode)
        }

        public func setRealtimeCaptionPrivacyModeEnabled(_ enabled: Bool) {
            guard realtimeCaptionPrivacyModeEnabled != enabled else { return }

            realtimeCaptionPrivacyModeEnabled = enabled
            defaults.set(enabled, forKey: StorageKeys.realtimeCaptionPrivacyModeEnabled)
        }
    #endif

    #if os(macOS) || os(iOS)
        public func setRealtimeTargetLanguage(
            _ option: TargetLanguageOption,
            reason: String = "AppPreferences.setRealtimeTargetLanguage"
        ) {
            guard realtimeTargetLanguage != option else { return }

            let oldValue = realtimeTargetLanguage.rawValue
            realtimeTargetLanguage = option
            defaults.set(option.rawValue, forKey: StorageKeys.realtimeTargetLanguage)
            logLanguageChange(
                field: "realtimeTargetLanguage",
                from: oldValue,
                to: option.rawValue,
                reason: reason
            )
        }

        public func setRealtimeSourceLanguage(
            _ option: SourceLanguageOption,
            reason: String = "AppPreferences.setRealtimeSourceLanguage"
        ) {
            guard realtimeSourceLanguage != option else { return }

            let oldValue = realtimeSourceLanguage.rawValue
            realtimeSourceLanguage = option
            defaults.set(option.rawValue, forKey: StorageKeys.realtimeSourceLanguage)
            logLanguageChange(
                field: "realtimeSourceLanguage",
                from: oldValue,
                to: option.rawValue,
                reason: reason
            )
        }

        public func setRealtimeTranslationProvider(_ provider: RealtimeTranslationProvider) {
            guard realtimeTranslationProvider != provider else { return }

            realtimeTranslationProvider = provider
            defaults.set(provider.rawValue, forKey: StorageKeys.realtimeTranslationProvider)
        }

        public func setRealtimeRecognitionEngine(_ engine: RealtimeRecognitionEngine) {
            guard realtimeRecognitionEngine != engine else { return }

            realtimeRecognitionEngine = engine
            defaults.set(engine.rawValue, forKey: StorageKeys.realtimeRecognitionEngine)
            setRealtimeRecognitionModelID(RecognitionModelStore.descriptor(for: engine).id)
        }

        public func setRealtimeRecognitionModelID(_ modelID: String) {
            let resolvedModelID = AppPreferences.validRealtimeRecognitionModelID(modelID)
            guard realtimeRecognitionModelID != resolvedModelID else { return }

            realtimeRecognitionModelID = resolvedModelID
            defaults.set(resolvedModelID, forKey: StorageKeys.realtimeRecognitionModelID)
        }

        public func setRealtimeShowCaptions(_ enabled: Bool) {
            guard realtimeShowCaptions != enabled else { return }

            realtimeShowCaptions = enabled
            defaults.set(enabled, forKey: StorageKeys.realtimeShowCaptions)
        }

        public func setRealtimeDualInputHistoryRecordingEnabled(_ enabled: Bool) {
            guard realtimeDualInputHistoryRecordingEnabled != enabled else { return }

            realtimeDualInputHistoryRecordingEnabled = enabled
            defaults.set(enabled, forKey: StorageKeys.realtimeDualInputHistoryRecordingEnabled)
        }
    #endif

    // MARK: - Enabled Models (flat model architecture)

    public func setEnabledModelIDs(_ ids: Set<String>) {
        guard enabledModelIDs != ids else { return }

        enabledModelIDs = ids
        defaults.set(Array(ids), forKey: StorageKeys.enabledModels)
    }

    public func setChatModelID(_ modelID: String?) {
        guard chatModelID != modelID else { return }

        chatModelID = modelID
        if let modelID {
            defaults.set(modelID, forKey: StorageKeys.chatModelID)
        } else {
            defaults.removeObject(forKey: StorageKeys.chatModelID)
        }
    }

    // MARK: - Apple Translate Installed Languages

    public func setAppleTranslateInstalledLanguages(_ languages: Set<String>) {
        guard appleTranslateInstalledLanguages != languages else { return }

        appleTranslateInstalledLanguages = languages
        defaults.set(Array(languages), forKey: StorageKeys.appleTranslateInstalledLanguages)
    }

    // MARK: - Voice Selection

    public func setSelectedVoiceID(_ voiceID: String) {
        guard selectedVoiceID != voiceID else { return }

        selectedVoiceID = voiceID
        defaults.set(voiceID, forKey: StorageKeys.selectedVoiceID)
    }

    // MARK: - Data Sharing Consent

    public func setHasAcceptedDataSharing(_ accepted: Bool) {
        guard hasAcceptedDataSharing != accepted else { return }

        hasAcceptedDataSharing = accepted
        defaults.set(accepted, forKey: StorageKeys.hasAcceptedDataSharing)
    }

    // MARK: - Accent Theme

    public func setAccentTheme(_ theme: AccentTheme) {
        guard accentTheme != theme else { return }

        accentTheme = theme
        defaults.set(theme.rawValue, forKey: StorageKeys.accentTheme)
    }

    // MARK: - Satisfaction Prompt

    public var shouldShowSatisfactionPrompt: Bool {
        let lastDate = defaults.object(forKey: StorageKeys.satisfactionPromptLastResponseDate) as? Date

        let isOldEnough = lastDate.map { Date().timeIntervalSince($0) >= 7 * 24 * 3600 } ?? true

        return isOldEnough
    }

    public func markSatisfactionPromptResponded() {
        defaults.set(Date(), forKey: StorageKeys.satisfactionPromptLastResponseDate)
    }

    /// Returns the iCloud Documents directory URL if available
    public static var iCloudDocumentsURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents", isDirectory: true)
    }

    public func refreshFromDefaults() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let storedResultOrder = AppPreferences.readModelResultOrder(from: defaults)
        if modelResultOrder != storedResultOrder {
            modelResultOrder = storedResultOrder
        }

        let resolved = AppPreferences.readTargetLanguage(from: defaults)
        if resolved != targetLanguage {
            let oldValue = targetLanguage.rawValue
            targetLanguage = resolved
            logLanguageChange(
                field: "targetLanguage",
                from: oldValue,
                to: resolved.rawValue,
                reason: "UserDefaults refresh"
            )
        }

        let resolvedSource = AppPreferences.readSourceLanguage(from: defaults)
        if resolvedSource != sourceLanguage {
            let oldValue = sourceLanguage.rawValue
            sourceLanguage = resolvedSource
            logLanguageChange(
                field: "sourceLanguage",
                from: oldValue,
                to: resolvedSource.rawValue,
                reason: "UserDefaults refresh"
            )
        }

        let storedConfigName = defaults.string(forKey: StorageKeys.currentConfigName)
        if currentConfigName != storedConfigName {
            currentConfigName = storedConfigName
        }

        let storedUseICloud = defaults.bool(forKey: StorageKeys.useICloudForConfig)
        if useICloudForConfig != storedUseICloud {
            useICloudForConfig = storedUseICloud
        }

        #if os(macOS)
            let storedOnboarding = defaults.bool(forKey: StorageKeys.hasCompletedOnboarding)
            if hasCompletedOnboarding != storedOnboarding {
                hasCompletedOnboarding = storedOnboarding
            }
            let storedOnboardingVersion = defaults.string(forKey: StorageKeys.lastCompletedOnboardingVersion)
            if lastCompletedOnboardingVersion != storedOnboardingVersion {
                lastCompletedOnboardingVersion = storedOnboardingVersion
            }
            let storedTextSelection = defaults.bool(forKey: StorageKeys.textSelectionTranslationEnabled)
            if textSelectionTranslationEnabled != storedTextSelection {
                textSelectionTranslationEnabled = storedTextSelection
            }
            let storedPopoverHeight = AppPreferences.readMenuBarPopoverHeight(from: defaults)
            if menuBarPopoverHeight != storedPopoverHeight {
                menuBarPopoverHeight = storedPopoverHeight
            }
            let storedPopoverWidth = AppPreferences.readMenuBarPopoverWidth(from: defaults)
            if menuBarPopoverWidth != storedPopoverWidth {
                menuBarPopoverWidth = storedPopoverWidth
            }
            let storedSelectionSize = AppPreferences.readSelectionPopupSize(from: defaults)
            if abs(selectionPopupWidth - storedSelectionSize.width) > 0.5 {
                selectionPopupWidth = storedSelectionSize.width
            }
            if abs(selectionPopupHeight - storedSelectionSize.height) > 0.5 {
                selectionPopupHeight = storedSelectionSize.height
            }
            let storedSelectionOrigin = AppPreferences.readSelectionPopupOrigin(from: defaults)
            if selectionPopupOrigin != storedSelectionOrigin {
                selectionPopupOrigin = storedSelectionOrigin
            }
            let storedRealtimeCaptionWindowMode = AppPreferences.readRealtimeCaptionWindowMode(from: defaults)
            if realtimeCaptionWindowMode != storedRealtimeCaptionWindowMode {
                realtimeCaptionWindowMode = storedRealtimeCaptionWindowMode
            }
            let storedRealtimeCaptionPrivacyModeEnabled = AppPreferences.readRealtimeCaptionPrivacyModeEnabled(from: defaults)
            if realtimeCaptionPrivacyModeEnabled != storedRealtimeCaptionPrivacyModeEnabled {
                realtimeCaptionPrivacyModeEnabled = storedRealtimeCaptionPrivacyModeEnabled
            }
        #endif

        #if os(macOS) || os(iOS)
            let storedRealtimeTargetLanguage = AppPreferences.readRealtimeTargetLanguage(
                from: defaults,
                preferredLanguages: Locale.preferredLanguages
            )
            if realtimeTargetLanguage != storedRealtimeTargetLanguage {
                let oldValue = realtimeTargetLanguage.rawValue
                realtimeTargetLanguage = storedRealtimeTargetLanguage
                logLanguageChange(
                    field: "realtimeTargetLanguage",
                    from: oldValue,
                    to: storedRealtimeTargetLanguage.rawValue,
                    reason: "UserDefaults refresh"
                )
            }
            let storedRealtimeSourceLanguage = AppPreferences.readRealtimeSourceLanguage(from: defaults)
            if realtimeSourceLanguage != storedRealtimeSourceLanguage {
                let oldValue = realtimeSourceLanguage.rawValue
                realtimeSourceLanguage = storedRealtimeSourceLanguage
                logLanguageChange(
                    field: "realtimeSourceLanguage",
                    from: oldValue,
                    to: storedRealtimeSourceLanguage.rawValue,
                    reason: "UserDefaults refresh"
                )
            }
            let storedRealtimeTranslationProvider = AppPreferences.readRealtimeTranslationProvider(from: defaults)
            if realtimeTranslationProvider != storedRealtimeTranslationProvider {
                realtimeTranslationProvider = storedRealtimeTranslationProvider
            }
            let storedRealtimeRecognitionEngine = AppPreferences.readRealtimeRecognitionEngine(from: defaults)
            if realtimeRecognitionEngine != storedRealtimeRecognitionEngine {
                realtimeRecognitionEngine = storedRealtimeRecognitionEngine
            }
            let storedRealtimeRecognitionModelID = AppPreferences.readRealtimeRecognitionModelID(from: defaults)
            if realtimeRecognitionModelID != storedRealtimeRecognitionModelID {
                realtimeRecognitionModelID = storedRealtimeRecognitionModelID
            }
            let storedRealtimeShowCaptions = AppPreferences.readRealtimeShowCaptions(from: defaults)
            if realtimeShowCaptions != storedRealtimeShowCaptions {
                realtimeShowCaptions = storedRealtimeShowCaptions
            }
            let storedRealtimeDualInputHistoryRecordingEnabled = defaults.bool(
                forKey: StorageKeys.realtimeDualInputHistoryRecordingEnabled
            )
            if realtimeDualInputHistoryRecordingEnabled != storedRealtimeDualInputHistoryRecordingEnabled {
                realtimeDualInputHistoryRecordingEnabled = storedRealtimeDualInputHistoryRecordingEnabled
            }
        #endif

        let storedEnabledModels = AppPreferences.readEnabledModelIDs(from: defaults)
        if enabledModelIDs != storedEnabledModels {
            enabledModelIDs = storedEnabledModels
        }

        let storedChatModelID = defaults.string(forKey: StorageKeys.chatModelID)
        if chatModelID != storedChatModelID {
            chatModelID = storedChatModelID
        }

        let storedVoiceID = defaults.string(forKey: StorageKeys.selectedVoiceID) ?? VoiceConfig.defaultVoiceID
        if selectedVoiceID != storedVoiceID {
            selectedVoiceID = storedVoiceID
        }

        let storedIsPremium = defaults.bool(forKey: StorageKeys.isPremium)
        if isPremium != storedIsPremium {
            isPremium = storedIsPremium
        }

        let storedHasAcceptedDataSharing = defaults.bool(forKey: StorageKeys.hasAcceptedDataSharing)
        if hasAcceptedDataSharing != storedHasAcceptedDataSharing {
            hasAcceptedDataSharing = storedHasAcceptedDataSharing
        }

        let storedHasSeenIOSPaywallOnboarding = defaults.bool(forKey: StorageKeys.hasSeenIOSPaywallOnboarding)
        if hasSeenIOSPaywallOnboarding != storedHasSeenIOSPaywallOnboarding {
            hasSeenIOSPaywallOnboarding = storedHasSeenIOSPaywallOnboarding
        }

        let storedHasSeenDefaultTranslationOnboarding = defaults.bool(forKey: StorageKeys.hasSeenDefaultTranslationOnboarding)
        if hasSeenDefaultTranslationOnboarding != storedHasSeenDefaultTranslationOnboarding {
            hasSeenDefaultTranslationOnboarding = storedHasSeenDefaultTranslationOnboarding
        }

        let storedHasCompletedDefaultTranslationTrial = defaults.bool(forKey: StorageKeys.hasCompletedDefaultTranslationTrial)
        if hasCompletedDefaultTranslationTrial != storedHasCompletedDefaultTranslationTrial {
            hasCompletedDefaultTranslationTrial = storedHasCompletedDefaultTranslationTrial
        }

        let storedLastDefaultTranslationTrialAt = defaults.object(forKey: StorageKeys.lastDefaultTranslationTrialAt) as? Date
        if lastDefaultTranslationTrialAt != storedLastDefaultTranslationTrialAt {
            lastDefaultTranslationTrialAt = storedLastDefaultTranslationTrialAt
        }

        let storedAccentTheme = AppPreferences.readAccentTheme(from: defaults)
        if accentTheme != storedAccentTheme {
            accentTheme = storedAccentTheme
        }

        let storedVoiceActionHint = defaults.bool(forKey: StorageKeys.voiceActionHintDismissed)
        if voiceActionHintDismissed != storedVoiceActionHint {
            voiceActionHintDismissed = storedVoiceActionHint
        }

        let storedInstalledLangs = AppPreferences.readInstalledLanguages(from: defaults)
        if appleTranslateInstalledLanguages != storedInstalledLangs {
            appleTranslateInstalledLanguages = storedInstalledLangs
        }
    }

    private static func resolveSharedDefaults() -> UserDefaults {
        UserDefaults.standard.addSuite(named: appGroupSuiteName)

        guard let defaults = UserDefaults(suiteName: appGroupSuiteName) else {
            assertionFailure("App group defaults unavailable. Falling back to standard defaults.")
            return .standard
        }
        return defaults
    }

    private func logLanguageChange(field: String, from oldValue: String?, to newValue: String?, reason: String) {
        let message = LanguageChangeLog.message(
            scope: "Preferences",
            field: field,
            from: oldValue,
            to: newValue,
            reason: reason
        )
        logger.debug("\(message, privacy: .public)")
    }

    private static func readTargetLanguage(from defaults: UserDefaults) -> TargetLanguageOption {
        let stored = defaults.string(forKey: TargetLanguageOption.storageKey)
        return TargetLanguageOption(rawValue: stored ?? "") ?? .appLanguage
    }

    private static func readSourceLanguage(from defaults: UserDefaults) -> SourceLanguageOption {
        let stored = defaults.string(forKey: SourceLanguageOption.storageKey)
        return SourceLanguageOption(rawValue: stored ?? "") ?? .auto
    }

    private static func readAccentTheme(from defaults: UserDefaults) -> AccentTheme {
        AccentTheme(rawValue: defaults.string(forKey: StorageKeys.accentTheme) ?? "") ?? .default
    }

    private static func readEnabledModelIDs(from defaults: UserDefaults) -> Set<String> {
        guard let array = defaults.stringArray(forKey: StorageKeys.enabledModels) else {
            return []
        }
        return Set(array)
    }

    private static func readInstalledLanguages(from defaults: UserDefaults) -> Set<String> {
        guard let array = defaults.stringArray(forKey: StorageKeys.appleTranslateInstalledLanguages) else {
            return []
        }
        return Set(array)
    }

    #if os(macOS)
        private static func readMenuBarPopoverHeight(from defaults: UserDefaults) -> CGFloat {
            let stored = defaults.double(forKey: StorageKeys.menuBarPopoverHeight)
            guard stored > 0 else { return menuBarPopoverDefaultHeight }
            return max(menuBarPopoverMinHeight, CGFloat(stored))
        }

        private static func readMenuBarPopoverWidth(from defaults: UserDefaults) -> CGFloat {
            let stored = defaults.double(forKey: StorageKeys.menuBarPopoverWidth)
            guard stored > 0 else { return menuBarPopoverDefaultWidth }
            return max(menuBarPopoverMinWidth, CGFloat(stored))
        }

        private static func readSelectionPopupSize(from defaults: UserDefaults) -> CGSize {
            let storedW = defaults.double(forKey: StorageKeys.selectionPopupWidth)
            let storedH = defaults.double(forKey: StorageKeys.selectionPopupHeight)
            let width = storedW > 0 ? CGFloat(storedW) : selectionPopupDefaultSize.width
            let height = storedH > 0 ? CGFloat(storedH) : selectionPopupDefaultSize.height
            return clampSelectionPopupSize(CGSize(width: width, height: height))
        }

        private static func readSelectionPopupOrigin(from defaults: UserDefaults) -> CGPoint? {
            guard defaults.object(forKey: StorageKeys.selectionPopupOriginX) != nil,
                  defaults.object(forKey: StorageKeys.selectionPopupOriginY) != nil
            else {
                return nil
            }
            return CGPoint(
                x: defaults.double(forKey: StorageKeys.selectionPopupOriginX),
                y: defaults.double(forKey: StorageKeys.selectionPopupOriginY)
            )
        }

        fileprivate static func clampSelectionPopupSize(_ size: CGSize) -> CGSize {
            let clampedWidth = min(max(selectionPopupMinSize.width, size.width.rounded()), selectionPopupMaxSize.width)
            let clampedHeight = min(max(selectionPopupMinSize.height, size.height.rounded()), selectionPopupMaxSize.height)
            return CGSize(width: clampedWidth, height: clampedHeight)
        }

        private static func readRealtimeCaptionWindowMode(from defaults: UserDefaults) -> RealtimeCaptionWindowMode {
            let stored = defaults.string(forKey: StorageKeys.realtimeCaptionWindowMode)
            return RealtimeCaptionWindowMode(rawValue: stored ?? "") ?? .floating
        }

        private static func readRealtimeCaptionPrivacyModeEnabled(from defaults: UserDefaults) -> Bool {
            guard defaults.object(forKey: StorageKeys.realtimeCaptionPrivacyModeEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: StorageKeys.realtimeCaptionPrivacyModeEnabled)
        }
    #endif

    #if os(macOS) || os(iOS)
        private static func readRealtimeTargetLanguage(
            from defaults: UserDefaults,
            preferredLanguages: [String]
        ) -> TargetLanguageOption {
            let stored = defaults.string(forKey: StorageKeys.realtimeTargetLanguage)
            return TargetLanguageOption(rawValue: stored ?? "")
                ?? TargetLanguageOption.defaultRealtimeTargetLanguage(preferredLanguages: preferredLanguages)
        }

        private static func readRealtimeSourceLanguage(from defaults: UserDefaults) -> SourceLanguageOption {
            let stored = defaults.string(forKey: StorageKeys.realtimeSourceLanguage)
            return SourceLanguageOption(rawValue: stored ?? "") ?? .english
        }

        private static func readRealtimeTranslationProvider(from defaults: UserDefaults) -> RealtimeTranslationProvider {
            let stored = defaults.string(forKey: StorageKeys.realtimeTranslationProvider)
            let provider = RealtimeTranslationProvider(rawValue: stored ?? "") ?? .default
            return provider.isAvailableOnCurrentOS ? provider : .default
        }

        private static func readRealtimeRecognitionEngine(from defaults: UserDefaults) -> RealtimeRecognitionEngine {
            let stored = defaults.string(forKey: StorageKeys.realtimeRecognitionEngine)
            return RealtimeRecognitionEngine(rawValue: stored ?? "") ?? .default
        }

        private static func readRealtimeRecognitionModelID(from defaults: UserDefaults) -> String {
            validRealtimeRecognitionModelID(defaults.string(forKey: StorageKeys.realtimeRecognitionModelID))
        }

        private static func validRealtimeRecognitionModelID(_ modelID: String?) -> String {
            guard let modelID else {
                return RecognitionModelStore.defaultRealtimeModel.id
            }
            return RecognitionModelStore.selectableDescriptor(forModelID: modelID).id
        }

        // Floating captions default to visible; only an explicit user opt-out is persisted.
        private static func readRealtimeShowCaptions(from defaults: UserDefaults) -> Bool {
            guard defaults.object(forKey: StorageKeys.realtimeShowCaptions) != nil else {
                return true
            }
            return defaults.bool(forKey: StorageKeys.realtimeShowCaptions)
        }
    #endif
}

private enum StorageKeys {
    static let modelResultOrder = "model_result_order"
    static let currentConfigName = "current_config_name"
    static let useICloudForConfig = "use_icloud_for_config"
    static let voiceActionHintDismissed = "voice_action_hint_dismissed"
    /// Key for enabled model IDs (flat model architecture)
    static let enabledModels = "enabled_models"
    static let chatModelID = "chat_model_id"
    /// Key for selected TTS voice ID
    static let selectedVoiceID = "selected_voice_id"
    /// Key for premium subscription status
    static let isPremium = "is_premium_subscriber"
    /// Key for data sharing consent
    static let hasAcceptedDataSharing = "has_accepted_data_sharing"
    /// Key for one-time iOS first-run paywall onboarding presentation
    static let hasSeenIOSPaywallOnboarding = "has_seen_ios_paywall_onboarding"
    static let hasSeenDefaultTranslationOnboarding = "ios_default_translation_onboarding_seen"
    static let hasCompletedDefaultTranslationTrial = "ios_default_translation_trial_completed"
    static let lastDefaultTranslationTrialAt = "ios_default_translation_trial_last_invoked_at"
    /// Key for accent theme preference
    static let accentTheme = "accent_theme"
    /// Key for Apple Translate installed language codes
    static let appleTranslateInstalledLanguages = "apple_translate_installed_languages"
    #if os(macOS)
        static let hasCompletedOnboarding = "has_completed_onboarding"
        static let lastCompletedOnboardingVersion = "last_completed_onboarding_version"
        static let textSelectionTranslationEnabled = "text_selection_translation_enabled"
        static let menuBarPopoverHeight = "menu_bar_popover_height"
        static let menuBarPopoverWidth = "menu_bar_popover_width"
        static let selectionPopupWidth = "selection_popup_width"
        static let selectionPopupHeight = "selection_popup_height"
        static let selectionPopupOriginX = "selection_popup_origin_x"
        static let selectionPopupOriginY = "selection_popup_origin_y"
        static let realtimeCaptionWindowMode = "realtime_caption_window_mode"
        static let realtimeCaptionPrivacyModeEnabled = "realtime_caption_privacy_mode_enabled"
    #endif
    #if os(macOS) || os(iOS)
        static let realtimeTargetLanguage = "realtime_target_language_code"
        static let realtimeSourceLanguage = "realtime_source_language_code"
        static let realtimeTranslationProvider = "realtime_translation_provider"
        static let realtimeRecognitionEngine = "realtime_recognition_engine"
        static let realtimeRecognitionModelID = "realtime_recognition_model_id"
        static let realtimeShowCaptions = "realtime_show_captions"
        static let realtimeDualInputHistoryRecordingEnabled = "realtime_dual_input_history_recording_enabled"
    #endif
    static let satisfactionPromptLastResponseDate = "satisfaction_prompt_last_response_date"
}
