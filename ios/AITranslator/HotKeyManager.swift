//
//  HotKeyManager.swift
//  TLingo
//
//  Created by AI Assistant on 2025/12/31.
//

#if os(macOS)
    import AppKit
    import Carbon
    import Combine
    import os
    import ShareCore

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "HotKey")

    /// Hot key configuration
    struct HotKeyConfiguration: Equatable, Codable {
        var keyCode: UInt32
        var modifiers: UInt32

        /// Empty configuration (no shortcut set)
        static let empty = HotKeyConfiguration(keyCode: 0, modifiers: 0)

        /// Whether the configuration is empty (no shortcut set)
        var isEmpty: Bool {
            keyCode == 0 && modifiers == 0
        }

        /// Returns the display string for modifier keys
        var modifiersDisplayString: String {
            var result = ""
            if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
            if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
            if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
            if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
            return result
        }

        /// Returns the display string for the key
        var keyDisplayString: String {
            keyCodeToString(keyCode)
        }

        /// Returns the full shortcut display string
        var displayString: String {
            if isEmpty { return String(localized: "Click to set") }
            return modifiersDisplayString + keyDisplayString
        }
    }

    /// Type of hotkey action
    enum HotKeyType: Int, CaseIterable {
        case mainApp = 1
        case quickTranslate = 2
        case selectionTranslate = 3
        case screenshotTranslate = 4
        case screenshotOCR = 5
        case clipboardTranslate = 6

        static var availableCases: [Self] {
            #if DIRECT_DISTRIBUTION
                allCases
            #else
                allCases.filter { $0 != .selectionTranslate }
            #endif
        }

        var displayName: String {
            switch self {
            case .mainApp: return String(localized: "Main App")
            case .quickTranslate: return String(localized: "Quick Translate")
            case .selectionTranslate: return String(localized: "Translate Selection")
            case .screenshotTranslate: return String(localized: "Screenshot Translate")
            case .screenshotOCR: return String(localized: "Screenshot OCR")
            case .clipboardTranslate: return String(localized: "Clipboard Translate")
            }
        }

        var description: String {
            switch self {
            case .mainApp: return String(localized: "Show/hide the main application window.")
            case .quickTranslate: return String(localized: "Show/hide the menu bar quick translate popover.")
            case .selectionTranslate: return String(localized: "Translate the text selected in any app.")
            case .screenshotTranslate: return String(localized: "Select a screen area and translate its text.")
            case .screenshotOCR: return String(localized: "Select a screen area and copy its text.")
            case .clipboardTranslate: return String(localized: "Translate the text or image on the clipboard.")
            }
        }

        var iconName: String {
            switch self {
            case .mainApp: return "macwindow"
            case .quickTranslate: return "bolt.fill"
            case .selectionTranslate: return "text.cursor"
            case .screenshotTranslate: return "text.viewfinder"
            case .screenshotOCR: return "doc.viewfinder"
            case .clipboardTranslate: return "doc.on.clipboard"
            }
        }

        fileprivate var storageKeyCode: String {
            switch self {
            case .mainApp: return "hotkey_main_keycode"
            case .quickTranslate: return "hotkey_quick_keycode"
            default: return "hotkey_\(rawValue)_keycode"
            }
        }

        fileprivate var storageModifiers: String {
            switch self {
            case .mainApp: return "hotkey_main_modifiers"
            case .quickTranslate: return "hotkey_quick_modifiers"
            default: return "hotkey_\(rawValue)_modifiers"
            }
        }

        fileprivate var signature: String {
            switch self {
            case .mainApp: return "AITM"
            case .quickTranslate: return "AITQ"
            default: return "AIT\(rawValue)"
            }
        }
    }

    /// Singleton class for managing global hotkeys.
    /// Supports independent hotkeys for the main app, quick translate, and translation actions.
    final class HotKeyManager: ObservableObject {
        static let shared = HotKeyManager()

        private var eventHandler: EventHandlerRef?
        private var registeredHotKeys: [HotKeyType: EventHotKeyRef] = [:]

        /// Current hotkey configurations
        @Published private(set) var mainAppConfiguration: HotKeyConfiguration
        @Published private(set) var quickTranslateConfiguration: HotKeyConfiguration
        @Published private(set) var actionConfigurations: [HotKeyType: HotKeyConfiguration] = [:]
        /// Hotkeys the system refused to register, usually because another app already uses them.
        @Published private(set) var unavailableHotKeys: Set<HotKeyType> = []

        private init() {
            let defaults = AppPreferences.sharedDefaults
            mainAppConfiguration = Self.loadHotKeyConfiguration(for: .mainApp, defaults: defaults)
            quickTranslateConfiguration = Self.loadHotKeyConfiguration(for: .quickTranslate, defaults: defaults)
            for type in HotKeyType.allCases where type != .mainApp && type != .quickTranslate {
                actionConfigurations[type] = Self.loadHotKeyConfiguration(for: type, defaults: defaults)
            }
        }

        private static func loadHotKeyConfiguration(
            for type: HotKeyType,
            defaults: UserDefaults
        ) -> HotKeyConfiguration {
            let keyCode = defaults.object(forKey: type.storageKeyCode) as? UInt32
            let modifiers = defaults.object(forKey: type.storageModifiers) as? UInt32
            if let keyCode, let modifiers, keyCode != 0 {
                return HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers)
            }
            return .empty
        }

        /// Returns the configuration for a specific hotkey type
        func configuration(for type: HotKeyType) -> HotKeyConfiguration {
            switch type {
            case .mainApp: return mainAppConfiguration
            case .quickTranslate: return quickTranslateConfiguration
            default: return actionConfigurations[type] ?? .empty
            }
        }

        /// Returns another hotkey type already using the given shortcut.
        func conflictingType(for configuration: HotKeyConfiguration, excluding type: HotKeyType) -> HotKeyType? {
            HotKeyType.availableCases.first { $0 != type && self.configuration(for: $0) == configuration }
        }

        /// Updates the hotkey configuration for a specific type
        func updateConfiguration(_ newConfiguration: HotKeyConfiguration, for type: HotKeyType) {
            let currentConfig = configuration(for: type)
            guard currentConfig != newConfiguration else { return }

            // Unregister the old hotkey first
            unregisterHotKey(for: type)

            // Update configuration
            switch type {
            case .mainApp:
                mainAppConfiguration = newConfiguration
            case .quickTranslate:
                quickTranslateConfiguration = newConfiguration
            default:
                actionConfigurations[type] = newConfiguration
            }

            // Save to UserDefaults
            let defaults = AppPreferences.sharedDefaults
            defaults.set(newConfiguration.keyCode, forKey: type.storageKeyCode)
            defaults.set(newConfiguration.modifiers, forKey: type.storageModifiers)

            // Register the new hotkey if not empty
            if !newConfiguration.isEmpty {
                registerHotKey(for: type)
            }
        }

        /// Clears the hotkey configuration for a specific type
        func clearConfiguration(for type: HotKeyType) {
            updateConfiguration(.empty, for: type)
        }

        /// Registers all global hotkeys
        func register() {
            guard eventHandler == nil else { return }

            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            // Install event handler
            let handlerResult = InstallEventHandler(
                GetApplicationEventTarget(),
                { _, event, _ -> OSStatus in
                    HotKeyManager.shared.handleHotKeyEvent(event)
                    return noErr
                },
                1,
                &eventType,
                nil,
                &eventHandler
            )

            guard handlerResult == noErr else {
                logger.error("Failed to install event handler: \(handlerResult, privacy: .public)")
                return
            }

            // Register all configured hotkeys
            for type in HotKeyType.allCases {
                let config = configuration(for: type)
                if !config.isEmpty {
                    registerHotKey(for: type)
                }
            }
        }

        /// Registers a specific hotkey with the system
        private func registerHotKey(for type: HotKeyType) {
            guard HotKeyType.availableCases.contains(type) else { return }
            guard registeredHotKeys[type] == nil else { return }

            let config = configuration(for: type)
            guard !config.isEmpty else { return }

            var hotKeyID = EventHotKeyID()
            hotKeyID.signature = OSType(type.signature.fourCharCodeValue)
            hotKeyID.id = UInt32(type.rawValue)

            var hotKeyRef: EventHotKeyRef?
            let registerResult = RegisterEventHotKey(
                config.keyCode,
                config.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if registerResult == noErr, let ref = hotKeyRef {
                registeredHotKeys[type] = ref
                unavailableHotKeys.remove(type)
            } else {
                unavailableHotKeys.insert(type)
                logger
                    .error(
                        "Failed to register hotkey for \(String(describing: type), privacy: .public): \(registerResult, privacy: .public)"
                    )
            }
        }

        /// Unregisters a specific hotkey from the system
        private func unregisterHotKey(for type: HotKeyType) {
            if let hotKey = registeredHotKeys[type] {
                UnregisterEventHotKey(hotKey)
                registeredHotKeys[type] = nil
            }
            unavailableHotKeys.remove(type)
        }

        /// Unregisters all global hotkeys and removes event handler
        func unregister() {
            for type in HotKeyType.allCases {
                unregisterHotKey(for: type)
            }

            if let handler = eventHandler {
                RemoveEventHandler(handler)
                eventHandler = nil
            }
        }

        /// Handles the hotkey event
        private func handleHotKeyEvent(_ event: EventRef?) {
            guard let event = event else { return }

            var hotKeyID = EventHotKeyID()
            let result = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard result == noErr else { return }

            DispatchQueue.main.async {
                if let type = HotKeyType(rawValue: Int(hotKeyID.id)) {
                    self.executeAction(for: type)
                }
            }
        }

        /// Executes the action for a specific hotkey type
        private func executeAction(for type: HotKeyType) {
            switch type {
            case .mainApp:
                toggleMainAppVisibility()
            case .quickTranslate:
                NotificationCenter.default.post(name: .toggleMenuBarPopover, object: nil)
            case .selectionTranslate:
                #if DIRECT_DISTRIBUTION
                    MainActor.assumeIsolated { AppDelegate.shared?.translateCurrentSelection() }
                #endif
            case .screenshotTranslate:
                MainActor.assumeIsolated { AppDelegate.shared?.translateScreenshot() }
            case .screenshotOCR:
                MainActor.assumeIsolated { AppDelegate.shared?.copyScreenshotText() }
            case .clipboardTranslate:
                MainActor.assumeIsolated { AppDelegate.shared?.translateClipboard() }
            }
        }

        /// Toggles the main app window visibility
        private func toggleMainAppVisibility() {
            let hasVisibleWindow = NSApp.windows.contains { window in
                window.isVisible && !window.isMiniaturized && window.canBecomeMain
            }

            if NSApp.isActive && hasVisibleWindow {
                NSApp.hide(nil)
            } else {
                AppDelegate.shared?.activateRegularMode()
                NSApp.activate(ignoringOtherApps: true)

                if !hasVisibleWindow {
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                } else {
                    for window in NSApp.windows where window.isVisible && window.canBecomeMain {
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
            }
        }
    }

    // MARK: - Notification Extension

    extension Notification.Name {
        static let toggleMenuBarPopover = Notification.Name("toggleMenuBarPopover")
    }

    // MARK: - String Extension

    private extension String {
        /// Converts a 4-character string to OSType
        var fourCharCodeValue: FourCharCode {
            guard count == 4 else { return 0 }

            var result: FourCharCode = 0
            for char in utf16 {
                result = (result << 8) + FourCharCode(char)
            }
            return result
        }
    }

    /// Converts a keyCode to a displayable string
    private func keyCodeToString(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "?"
        }
    }
#endif
