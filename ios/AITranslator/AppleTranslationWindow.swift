//
//  AppleTranslationWindow.swift
//  TLingo
//
//  A hidden NSWindow that hosts the .translationTask() modifier on macOS.
//  Apple's Translation framework requires a proper NSWindowScene (not an NSPopover)
//  to present its UI. This window satisfies that requirement without being visible.
//

#if os(macOS)
    import AppKit
    import Combine
    import os
    import ShareCore
    import SwiftUI
    import Translation

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "AppleTranslationBridge")

    // MARK: - Bridge

    /// Coordinates Apple Translate requests between HomeViewModel and the hidden translation window.
    @MainActor
    final class AppleTranslationBridge: ObservableObject {
        static let shared = AppleTranslationBridge()

        /// Pending translation configuration. The hidden window view observes this.
        @Published var pendingConfig: TranslationSession.Configuration?

        /// Weak reference to the view model that owns the current Apple Translate request.
        weak var activeViewModel: HomeViewModel?

        private init() {}

        /// Called by HomeViewModel (via its appleTranslationRequestHandler closure) to trigger
        /// a translation through the hidden window.
        @available(macOS 14.4, *)
        func requestTranslation(
            source: Locale.Language?,
            target: TargetLanguageOption,
            for viewModel: HomeViewModel
        ) {
            activeViewModel = viewModel
            let targetLocale = target.localeLanguage
            logger.debug("requestTranslation source=\(source?.languageCode?.identifier ?? "nil (auto)", privacy: .public), target=\(targetLocale.languageCode?.identifier ?? "unknown", privacy: .public), viewModel=\(String(describing: ObjectIdentifier(viewModel)), privacy: .public)")

            // Capture a strong reference so the correct viewModel is used even if
            // activeViewModel is overwritten by another registration before the Task runs.
            Task { @MainActor [viewModel] in
                do {
                    let status = try await AppleTranslationService.shared.languageAvailabilityStatus(
                        source: source, target: targetLocale
                    )
                    logger
                        .debug(
                            "language availability: \(String(describing: status), privacy: .public) for viewModel=\(String(describing: ObjectIdentifier(viewModel)), privacy: .public)"
                        )
                    if status == .supported {
                        AppleTranslationWindowManager.shared.showForLanguageDownload()
                    } else if status != .installed {
                        logger
                            .error(
                                "Apple Translate bridge: unsupported language pair source=\(source?.minimalIdentifier ?? "nil", privacy: .public), target=\(targetLocale.minimalIdentifier, privacy: .public), status=\(String(describing: status), privacy: .public). .translationTask will fail with no result."
                            )
                    }
                } catch {
                    logger
                        .error(
                            "Apple Translate bridge: language availability failed: \(String(describing: error), privacy: .public)"
                        )
                }

                if self.pendingConfig != nil {
                    self.pendingConfig?.invalidate()
                    self.pendingConfig = nil
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                // Store the viewModel for this specific request so sessionReady delivers to the right one.
                self.activeViewModel = viewModel
                self.pendingConfig = .init(source: source, target: targetLocale)
            }
        }

        /// Called by the hidden window view when a TranslationSession becomes available.
        @available(macOS 14.4, *)
        func sessionReady(_ session: TranslationSession) {
            let vmId = activeViewModel.map { "\(ObjectIdentifier($0))" } ?? "nil"
            logger.debug("sessionReady, activeViewModel=\(vmId, privacy: .public)")
            activeViewModel?.executeAppleTranslation(session: session)
        }
    }

    // MARK: - Hidden Window View

    /// A zero-size view that holds the .translationTask() modifier.
    @available(macOS 14.4, *)
    struct AppleTranslationWindowView: View {
        @ObservedObject private var bridge = AppleTranslationBridge.shared

        var body: some View {
            Color.clear
                .frame(width: 1, height: 1)
                .translationTask(bridge.pendingConfig) { session in
                    logger.debug(".translationTask fired")
                    AppleTranslationBridge.shared.sessionReady(session)
                }
        }
    }

    // MARK: - Window Manager

    /// Manages the lifecycle of the hidden translation window.
    @MainActor
    final class AppleTranslationWindowManager {
        static let shared = AppleTranslationWindowManager()

        private var window: NSWindow?
        private var viewModelObserver: NSObjectProtocol?
        private var prepareCompletedObserver: NSObjectProtocol?
        /// ViewModels that registered before the window was ready.
        private var pendingViewModels: [WeakRef<HomeViewModel>] = []

        private init() {
            // Start listening immediately so viewModels that register before setup() don't get lost.
            viewModelObserver = NotificationCenter.default.addObserver(
                forName: .appleTranslationViewModelRegister,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self,
                      let viewModel = notification.userInfo?["viewModel"] as? HomeViewModel
                else { return }
                Task { @MainActor in
                    if self.window != nil {
                        if #available(macOS 14.4, *) { self.registerViewModel(viewModel) }
                    } else {
                        self.pendingViewModels.append(WeakRef(viewModel))
                        logger.debug("Queued viewModel (window not ready yet)")
                    }
                }
            }
        }

        func setup() {
            guard window == nil else { return }
            guard #available(macOS 14.4, *) else { return }

            let size = NSSize(width: 400, height: 300)
            let hostingView = NSHostingView(rootView: AppleTranslationWindowView())
            hostingView.frame = NSRect(origin: .zero, size: size)

            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            win.contentView = hostingView
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            win.level = .floating
            win.isOpaque = false
            win.backgroundColor = .clear
            win.ignoresMouseEvents = true
            win.hasShadow = false
            win.alphaValue = 0
            // Move far off-screen so it's part of a real NSWindowScene but completely invisible.
            // Must be shown (orderFront) for .translationTask to get a valid session.
            win.setFrameOrigin(NSPoint(x: -9999, y: -9999))
            win.orderFront(nil)

            self.window = win
            logger.debug("Hidden translation window created")

            // Register any viewModels that arrived before we were ready.
            for ref in pendingViewModels {
                if let vm = ref.value { registerViewModel(vm) }
            }
            pendingViewModels.removeAll()

            // Hide the auxiliary window once prepareTranslation() completes.
            prepareCompletedObserver = NotificationCenter.default.addObserver(
                forName: .appleTranslationPrepareCompleted,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.hideAfterSessionReady()
                }
            }
        }

        func teardown() {
            if let observer = viewModelObserver {
                NotificationCenter.default.removeObserver(observer)
                viewModelObserver = nil
            }
            if let observer = prepareCompletedObserver {
                NotificationCenter.default.removeObserver(observer)
                prepareCompletedObserver = nil
            }
            window?.close()
            window = nil
            pendingViewModels.removeAll()
        }

        /// Moves the auxiliary window to screen center and makes it visible.
        /// Called when a language pack needs to be downloaded so the system UI appears on screen.
        func showForLanguageDownload() {
            guard let win = window, let screen = NSScreen.main else { return }
            // Center the window on screen so the system download sheet appears in the middle.
            let sf = screen.visibleFrame
            let wf = win.frame
            let origin = NSPoint(
                x: sf.minX + (sf.width - wf.width) / 2,
                y: sf.minY + (sf.height - wf.height) / 2
            )
            win.setFrameOrigin(origin)
            win.alphaValue = 1
            win.orderFront(nil)
            logger.debug("Shown for language download at \(String(describing: origin), privacy: .public)")
        }

        /// Hides the auxiliary window after the session is ready (language pack was installed).
        func hideAfterSessionReady() {
            guard let win = window else { return }
            win.alphaValue = 0
            win.setFrameOrigin(NSPoint(x: -9999, y: -9999))
            logger.debug("Hidden after session ready")
        }

        /// Wires the bridge request handler into a HomeViewModel instance.
        @available(macOS 14.4, *)
        private func registerViewModel(_ viewModel: HomeViewModel) {
            viewModel.appleTranslationRequestHandler = { [weak viewModel] source, target in
                guard let viewModel else { return }
                AppleTranslationBridge.shared.requestTranslation(
                    source: source,
                    target: target,
                    for: viewModel
                )
            }
            logger.debug("Registered viewModel \(String(describing: ObjectIdentifier(viewModel)), privacy: .public)")
        }
    }

    // MARK: - WeakRef helper

    private final class WeakRef<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
#endif
