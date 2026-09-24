//
//  AITranslatorApp.swift
//  TLingo
//
//  Created by Zander Wang on 2025/10/18.
//

import os
import ShareCore
import SwiftUI
#if os(macOS)
    import UniformTypeIdentifiers
#endif
#if os(macOS)
    import Combine
#endif

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "App")
#if os(macOS)
    import AppKit

    private enum MainWindowMetrics {
        static let defaultWidth: CGFloat = 1280
        static let defaultHeight: CGFloat = 800
        static let minWidth: CGFloat = 1040
        static let minHeight: CGFloat = 640
        static let snapshotWidth: CGFloat = 1600
        static let snapshotHeight: CGFloat = 900
    }
#endif

@main
struct AITranslatorApp: App {
    #if os(iOS)
        @UIApplicationDelegateAdaptor(IOSAppDelegate.self) private var iosAppDelegate
    #endif

    #if os(macOS)
        @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        // Distribution channel marker. MUST run before any ShareCore code
        // touches StoreManager / AppPreferences / Entitlement, otherwise those
        // singletons will initialize on the App Store path even in a Direct
        // binary. We rely on the compile-time `DIRECT_DISTRIBUTION` flag here
        // (defined only on the TLingo-Direct app target) and pass the result
        // into ShareCore as a runtime value, because ShareCore is built once
        // and shared by both targets — it cannot see the macro itself.
        #if DIRECT_DISTRIBUTION
            BuildEnvironment.markAsDirectDistribution()
        #endif

        // Debug: Print configuration on launch
        #if DEBUG
            logger.info("AITranslator launching...")
            logger
                .info("Distribution channel: \(BuildEnvironment.isDirectDistribution ? "direct" : "appstore", privacy: .public)")
            logger.debug("\(BuildEnvironment.debugDescription, privacy: .public)")
            let secret = AppSecrets.cloudSecret
            if secret.isEmpty {
                logger.warning("Cloud secret is empty!")
            }
            // Also write args to /tmp (stdout is unreliable when launched via open)
            let dbg = "/tmp/tlingo_launch_args.txt"
            let args = ProcessInfo.processInfo.arguments.joined(separator: "\n") + "\n"
            try? args.write(toFile: dbg, atomically: true, encoding: .utf8)
        #endif
    }

    static var isSnapshotMode: Bool {
        HomeViewModel.isSnapshotMode
    }

    #if os(macOS)
        static var currentAppVersion: String {
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        }
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            #if os(macOS)
                MainWindowContent()
            #else
                RootTabView()
            #endif
        }
        #if os(macOS)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(Self.isSnapshotMode ? .suppressed : .presented)
        #endif
        // Match BOTH URL schemes so deeplinks reuse the existing window instead
        // of spawning a new one. `tlingo-direct://oauth/callback` (Supabase OAuth
        // return) is Direct-only; if it isn't listed here SwiftUI opens a fresh
        // WindowGroup instance to receive the event.
        .handlesExternalEvents(matching: ["tlingo-direct", "tlingo"])
        #if os(macOS)
            .commands {
                CommandGroup(after: .help) {
                    Button("Export Logs...") {
                        exportLogsFromHelpMenu()
                    }
                }
                #if DIRECT_DISTRIBUTION
                    CommandGroup(after: .appInfo) {
                        CheckForUpdatesView()
                        Divider()
                        SignInMenuItem()
                    }
                #endif
            }
        #endif
    }

    #if os(macOS)
        /// Configure the main window for screenshot capture mode
        static func configureSnapshotWindow() {
            if let window = snapshotWindow {
                window.setContentSize(NSSize(
                    width: MainWindowMetrics.snapshotWidth,
                    height: MainWindowMetrics.snapshotHeight
                ))
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                // Retry after a delay if window not yet available
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Self.configureSnapshotWindow()
                }
            }
        }

        static var snapshotWindow: NSWindow? {
            NSApp.windows
                .filter { $0.canBecomeMain && $0.isVisible }
                .max { lhs, rhs in
                    lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
                }
        }

        private func exportLogsFromHelpMenu() {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "tlingo-logs-\(Self.fileDateStamp()).log"
            panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    do {
                        try DiagnosticLogExporter.writeLog(to: url)
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } catch {
                        logger.error("Export logs failed: \(error.localizedDescription, privacy: .public)")
                        let alert = NSAlert(error: error)
                        alert.runModal()
                    }
                }
            }
        }

        private static func fileDateStamp() -> String {
            ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
        }
    #endif
}

#if os(macOS)
    /// Wrapper view that captures the openWindow environment action and provides it to AppDelegate
    struct MainWindowContent: View {
        @Environment(\.openWindow) private var openWindow
        @ObservedObject private var prefs = AppPreferences.shared
        @State private var showOnboarding = false

        var body: some View {
            RootTabView()
                .frame(minWidth: MainWindowMetrics.minWidth, minHeight: MainWindowMetrics.minHeight)
            #if DEBUG
                .background(AppleTranslationStrategyBenchmarkView())
            #endif
                .handlesExternalEvents(preferring: ["tlingo-direct", "tlingo"], allowing: ["*"])
                .onAppear {
                    AppDelegate.shared?.openWindowAction = openWindow

                    if AITranslatorApp.isSnapshotMode {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            AITranslatorApp.configureSnapshotWindow()
                        }

                        // NOTE: Snapshot export is handled in AppDelegate.applicationDidFinishLaunching.
                        return
                    }

                    if RootTabView.forceOnboarding || !prefs.hasCompletedOnboarding {
                        showOnboarding = true
                    }
                }
                .sheet(isPresented: $showOnboarding) {
                    OnboardingView(isPresented: $showOnboarding)
                }
        }
    }

    /// macOS app delegate for managing global hotkeys and Services
    final class AppDelegate: NSObject, NSApplicationDelegate {
        /// Shared instance for accessing the received text from Services
        static var shared: AppDelegate?

        /// Stored SwiftUI openWindow action for creating new windows
        var openWindowAction: OpenWindowAction?

        private var mainWindow: NSWindow?
        private var windowObservers: [NSObjectProtocol] = []
        private let selectionTranslationCoordinator = SelectionTranslationCoordinator()
        private var selectionTranslationCancellable: AnyCancellable?

        override init() {
            super.init()
            // Set shared early so SwiftUI views can access it during onAppear
            // (which may fire before applicationDidFinishLaunching)
            AppDelegate.shared = self
            // Touch the AppleTranslationWindowManager singleton early so its notification
            // observer is registered before any HomeView.onAppear fires.
            _ = AppleTranslationWindowManager.shared
        }

        @MainActor
        func showSelectionTrigger(near point: CGPoint) {
            selectionTranslationCoordinator.showTrigger(near: point)
        }

        @MainActor
        func dismissSelectionTrigger() {
            selectionTranslationCoordinator.dismissTrigger()
        }

        @MainActor
        func setSelectionTrialCallbacks(
            actionName: String? = nil,
            trialModels: [ModelConfig] = [],
            onTriggerHovered: @escaping () -> Void,
            onTranslationSucceeded: @escaping () -> Void
        ) {
            selectionTranslationCoordinator.setSelectionTrialCallbacks(
                actionName: actionName,
                trialModels: trialModels,
                onTriggerHovered: onTriggerHovered,
                onTranslationSucceeded: onTranslationSucceeded
            )
        }

        @MainActor
        func clearSelectionTrialCallbacks() {
            selectionTranslationCoordinator.clearSelectionTrialCallbacks()
        }

        @MainActor
        func translateCurrentSelection() {
            selectionTranslationCoordinator.translateCurrentSelection()
        }

        @MainActor
        func translateScreenshot() {
            Task { @MainActor in
                guard let text = await ScreenshotOCR.captureAndRecognize() else { return }
                selectionTranslationCoordinator.translate(text: text)
            }
        }

        @MainActor
        func copyScreenshotText() {
            Task { @MainActor in
                guard let text = await ScreenshotOCR.captureAndRecognize() else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                NSSound(named: "Pop")?.play()
            }
        }

        /// Translates clipboard text, or the text recognized in a clipboard image.
        @MainActor
        func translateClipboard() {
            Task { @MainActor in
                let text = NSPasteboard.general.string(forType: .string)
                if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    selectionTranslationCoordinator.translate(text: text)
                } else if let text = await ScreenshotOCR.recognizeClipboardImage() {
                    selectionTranslationCoordinator.translate(text: text)
                }
            }
        }

        func applicationDidFinishLaunching(_: Notification) {
            // In snapshot mode, skip menu bar/hotkey setup and force window creation
            if AITranslatorApp.isSnapshotMode {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.openMainWindow()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        AITranslatorApp.configureSnapshotWindow()
                    }
                }
                return
            }

            // Start clipboard monitoring for auto-translate feature
            ClipboardMonitor.shared.startMonitoring()

            // Register global hotkey (Option + T by default)
            HotKeyManager.shared.register()

            // Setup menu bar status item
            Task { @MainActor in
                MenuBarManager.shared.setup()
            }

            // Register this object as a service provider for handling text from right-click menu
            NSApp.servicesProvider = self

            // Register the pasteboard types this app can receive via Services
            // This tells the system that this app can accept string data from the Services menu
            NSApp.registerServicesMenuSendTypes([.string], returnTypes: [])

            // Force update dynamic services
            NSUpdateDynamicServices()

            // Observe window lifecycle for smart Dock icon management
            setupWindowObservers()

            selectionTranslationCancellable = AppPreferences.shared.$textSelectionTranslationEnabled
                .sink { [weak self] enabled in
                    if enabled {
                        self?.selectionTranslationCoordinator.start()
                    } else {
                        self?.selectionTranslationCoordinator.stop()
                    }
                }
        }

        func applicationWillTerminate(_: Notification) {
            // Stop clipboard monitoring
            ClipboardMonitor.shared.stopMonitoring()

            // Unregister global hotkey
            HotKeyManager.shared.unregister()

            selectionTranslationCoordinator.stop()
            selectionTranslationCancellable?.cancel()

            // Teardown menu bar
            Task { @MainActor in
                MenuBarManager.shared.teardown()
            }

            // Remove window observers
            for observer in windowObservers {
                NotificationCenter.default.removeObserver(observer)
            }
            windowObservers.removeAll()
        }

        func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
            false
        }

        func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows _: Bool) -> Bool {
            openMainWindow()
            return true
        }

        // MARK: - URL handling (intercept BEFORE SwiftUI spawns a new window)

        func application(_: NSApplication, open urls: [URL]) {
            let urlSummary = urls.map(\.redactedLogDescription).joined(separator: ", ")
            logger
                .info(
                    "AppDelegate.application(open:) urls=\(urlSummary, privacy: .public)"
                )
            let visibleCount = NSApp.windows.filter(\.isVisible).count
            logger
                .info(
                    "windows count=\(NSApp.windows.count, privacy: .public) visible=\(visibleCount, privacy: .public)"
                )
            for (index, window) in NSApp.windows.enumerated() {
                let typeName = String(describing: type(of: window))
                logger
                    .info(
                        """
                        [\(index, privacy: .public)] title=\(window.title, privacy: .public) \
                        visible=\(window.isVisible, privacy: .public) \
                        canBecomeMain=\(window.canBecomeMain, privacy: .public) \
                        class=\(typeName, privacy: .public)
                        """
                    )
            }
            for url in urls {
                #if DIRECT_DISTRIBUTION
                    if OAuthCoordinator.shared.handleCallbackIfMatching(url) {
                        logger.info("OAuth callback consumed by AppDelegate; bringing existing window to front")
                        openMainWindow()
                        continue
                    }
                #endif
                // Other deep links (e.g. tlingo://translate) are delivered by
                // SwiftUI's onOpenURL on RootTabView. We don't re-post the
                // notification here: NotificationCenter doesn't buffer, so
                // posting before the view mounts (cold launch / menu-bar-only)
                // would silently drop the payload.
            }
        }

        // MARK: - Smart Dock Icon Management

        /// Show Dock icon and menu bar (regular app mode)
        func activateRegularMode() {
            NSApp.setActivationPolicy(.regular)
        }

        /// Hide Dock icon when no windows are visible (menu bar-only mode)
        private func activateAccessoryModeIfNeeded() {
            let hasVisibleMainWindow = NSApp.windows.contains {
                $0.isVisible && !$0.isMiniaturized && $0.canBecomeMain
            }
            if !hasVisibleMainWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }

        private func setupWindowObservers() {
            // When a window becomes main, show Dock icon
            let mainObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.activateRegularMode()
            }

            // When a window closes, hide Dock icon if no other windows remain
            let closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Delay check to let the window fully close
                DispatchQueue.main.async {
                    self?.activateAccessoryModeIfNeeded()
                }
            }

            windowObservers = [mainObserver, closeObserver]
        }

        /// Opens or brings the main window to front
        func openMainWindow() {
            activateRegularMode()

            if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
            } else if let openWindow = openWindowAction {
                openWindow(id: "main")
                // Delay activation to let the window appear after policy switch
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
            } else {
                createMainWindowViaAppKit()
            }
        }

        /// Creates the main window directly via AppKit when SwiftUI's openWindow is unavailable
        private func createMainWindowViaAppKit() {
            let contentSize = AITranslatorApp.isSnapshotMode
                ? NSSize(width: MainWindowMetrics.snapshotWidth, height: MainWindowMetrics.snapshotHeight)
                : NSSize(width: MainWindowMetrics.defaultWidth, height: MainWindowMetrics.defaultHeight)
            let hostingController = NSHostingController(rootView: MainWindowContent())
            let window = NSWindow(
                contentRect: NSRect(
                    x: 0,
                    y: 0,
                    width: contentSize.width,
                    height: contentSize.height
                ),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            if AITranslatorApp.isSnapshotMode {
                window.title = "TLingo Snapshot"
            }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .unified
            window.minSize = NSSize(width: MainWindowMetrics.minWidth, height: MainWindowMetrics.minHeight)
            window.contentViewController = hostingController
            mainWindow = window
            window.center()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }

        /// Service handler for translating text from right-click menu
        /// This method name must match the NSMessage value in Info.plist
        @objc func translateText(
            _ pboard: NSPasteboard,
            userData _: String?,
            error: AutoreleasingUnsafeMutablePointer<NSString?>
        ) {
            guard let text = pboard.string(forType: .string), !text.isEmpty else {
                error.pointee = "No text provided" as NSString
                return
            }

            // Store the received text and bring app to foreground
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)

                // Post notification so UI can respond
                NotificationCenter.default.post(
                    name: .serviceTextReceived,
                    object: nil,
                    userInfo: ["text": text]
                )
            }
        }
    }
#endif
