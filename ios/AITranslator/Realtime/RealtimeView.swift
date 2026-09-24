#if os(macOS)
    import AVFoundation
    import ShareCore
    import SwiftUI
    import UniformTypeIdentifiers

    struct RealtimeView: View {
        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject private var store: RealtimeSessionStore
        @StateObject private var permissionManager = RealtimePermissionManager()
        @State private var isFloatingCaptionVisible = RealtimeFloatingCaptionWindowController.isOpen
        @State private var isInspectorPresented: Bool
        @State private var isAdvancedSettingsExpanded = false
        @State private var isStartingRealtimeSession = false
        @State private var isRealtimeOnboardingPresented = false
        @State private var inspectorWidth: CGFloat = InspectorColumnWidth.ideal
        @State private var inspectorDragStartWidth: CGFloat?
        @State private var isAddingLane = false
        @State private var laneConfigurationError: String?
        @State private var isAudioImporterPresented = false
        @State private var audioImportError: String?

        init(store: RealtimeSessionStore) {
            self.store = store
            _isInspectorPresented = State(initialValue: MacSnapshotScene.current() != .realtimeMultiLane)
        }

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        private var isRealtimeSessionStarting: Bool {
            isStartingRealtimeSession || store.isStarting
        }

        private var isRealtimeSessionBusy: Bool {
            store.isRunning || isRealtimeSessionStarting || store.isStopping
        }

        var body: some View {
            captionPane
                .background(colors.background.ignoresSafeArea())
                .safeAreaInset(edge: .top, spacing: 0) {
                    RealtimeSetupPromptView(
                        store: store,
                        preferences: preferences,
                        permissionManager: permissionManager,
                        isOnboardingPresented: $isRealtimeOnboardingPresented,
                        inspectorTrailingPadding: isInspectorPresented ? inspectorWidth + 20 : 20
                    )
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    controls
                }
                .tint(colors.accent)
                .overlay {
                    if isRealtimeSessionStarting || store.isStopping {
                        RealtimeProgressOverlay(
                            preferences: preferences,
                            isStopping: store.isStopping,
                            statusText: store.statusText
                        )
                    }
                }
                .overlay(alignment: .trailing) {
                    if isInspectorPresented {
                        realtimeInspectorPanel
                            .transition(inspectorTransition)
                    }
                }
                .animation(.easeInOut(duration: 0.16), value: isRealtimeSessionStarting)
                .animation(.easeInOut(duration: 0.16), value: store.isStopping)
                .animation(.easeInOut(duration: 0.16), value: isInspectorPresented)
                .toolbar {
                    ToolbarSpacer(.flexible)

                    ToolbarItem {
                        Button {
                            Task {
                                await addRealtimeLane()
                            }
                        } label: {
                            Label("Add Realtime Lane", systemImage: "plus")
                        }
                        .help("Add realtime lane")
                        .disabled(!store.canAddRealtimeLane || store.isStopping || isAddingLane)
                    }
                }
                .toolbarBackground(.hidden, for: .windowToolbar)
                .onAppear {
                    guard !SnapshotLaunchArguments.isSnapshotMode() else { return }
                    if store.showCaptions {
                        RealtimeFloatingCaptionWindowController.open(store: store)
                    }
                    permissionManager.refresh()
                    permissionManager.startPolling()
                    syncFloatingCaptionVisibility()
                }
                .onDisappear {
                    permissionManager.stopPolling()
                }
                .onChange(of: preferences.realtimeRecognitionModelID) {
                    guard let primaryLane = store.primaryLaneConfiguration else { return }
                    store.updateLane(
                        id: primaryLane.id,
                        recognitionModelID: preferences.realtimeRecognitionModelID,
                        translationProvider: primaryLane.translationProvider
                    )
                }
                .onChange(of: preferences.realtimeCaptionWindowMode) {
                    refreshFloatingCaptionWindowIfVisible()
                }
                .onChange(of: preferences.realtimeCaptionPrivacyModeEnabled) {
                    refreshFloatingCaptionWindowIfVisible()
                }
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: RealtimeFloatingCaptionWindowController.visibilityDidChangeNotification)
                ) { _ in
                    syncFloatingCaptionVisibility()
                }
                .alert(
                    store.startFailureAlert?.title ?? "Realtime Failed",
                    isPresented: startFailureAlertPresentedBinding
                ) {
                    Button("OK", role: .cancel) {
                        store.dismissStartFailureAlert()
                    }
                } message: {
                    Text(store.startFailureAlert?.message ?? "")
                }
                .alert(
                    "Realtime Lane",
                    isPresented: Binding(
                        get: { laneConfigurationError != nil },
                        set: { if !$0 { laneConfigurationError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        laneConfigurationError = nil
                    }
                } message: {
                    Text(laneConfigurationError ?? "")
                }
                .alert(
                    "Import Failed",
                    isPresented: Binding(
                        get: { audioImportError != nil },
                        set: { if !$0 { audioImportError = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) {
                        audioImportError = nil
                    }
                } message: {
                    Text(audioImportError ?? "")
                }
                .fileImporter(
                    isPresented: $isAudioImporterPresented,
                    allowedContentTypes: [.audio],
                    allowsMultipleSelection: false
                ) { result in
                    handleAudioImport(result)
                }
                .sheet(isPresented: $isRealtimeOnboardingPresented) {
                    OnboardingView(
                        isPresented: $isRealtimeOnboardingPresented,
                        initialStep: 2,
                        isSingleStep: true
                    )
                }
        }
    }

    private extension RealtimeView {
        private var inspectorTransition: AnyTransition {
            reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity)
        }

        private var captionPane: some View {
            RealtimeLaneWorkspace(
                store: store,
                accentTheme: preferences.accentTheme,
                sourceLanguage: preferences.realtimeSourceLanguage
            )
            .padding(.trailing, isInspectorPresented ? inspectorWidth : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private var controls: some View {
            RealtimeTransportBar(
                store: store,
                preferences: preferences,
                isInspectorPresented: $isInspectorPresented,
                isStarting: isRealtimeSessionStarting,
                canStart: canStartRealtimeSession,
                startHelp: startButtonHelp,
                onStart: {
                    Task { await toggleRealtimeSession() }
                },
                onEnd: {
                    Task { await store.endSession() }
                },
                onImportAudio: {
                    isAudioImporterPresented = true
                },
                onClearImportedAudio: {
                    store.setImportedAudioURL(nil)
                },
                onLanguageChanged: {
                    store.languageSelectionDidChange()
                }
            )
            .padding(.horizontal, 20)
            .padding(.trailing, isInspectorPresented ? inspectorWidth : 0)
            .padding(.top, 8)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }

        private var realtimeInspectorPanel: some View {
            realtimeInspector
                .frame(width: inspectorWidth)
                .frame(maxHeight: .infinity)
                .background(Color.clear)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.clear)
                        .frame(width: 10)
                        .overlay(alignment: .leading) {
                            Divider()
                        }
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { value in
                                    let startWidth = inspectorDragStartWidth ?? inspectorWidth
                                    inspectorDragStartWidth = startWidth
                                    inspectorWidth = InspectorColumnWidth.clamped(startWidth - value.translation.width)
                                }
                                .onEnded { _ in
                                    inspectorDragStartWidth = nil
                                }
                        )
                        .accessibilityHidden(true)
                }
        }

        private var realtimeInspector: some View {
            RealtimeInspectorView(
                preferences: preferences,
                isFloatingCaptionVisible: $isFloatingCaptionVisible,
                isAdvancedSettingsExpanded: $isAdvancedSettingsExpanded,
                isBusy: isRealtimeSessionBusy,
                recordingBinding: realtimeDualInputHistoryRecordingBinding,
                captionWindowModeBinding: captionWindowModeBinding,
                captionPrivacyBinding: realtimeCaptionPrivacyBinding,
                onFloatingCaptionVisibilityChanged: setFloatingCaptionsVisible
            )
        }

        private var startButtonHelp: String {
            if let startBlocker {
                return startBlocker.localizedDescription
            }
            return String(localized: "Start realtime translation")
        }

        private var canStartRealtimeSession: Bool {
            startBlocker == nil
        }

        private var startBlocker: RealtimeStartBlocker? {
            if store.isStopping {
                return .stopping
            }
            if isRealtimeSessionStarting {
                return .starting
            }
            guard store.hasRequiredLanguageSelection else {
                return .missingLanguageSelection
            }
            if let blocker = store.laneConfigurationStartBlocker {
                return blocker
            }
            return nil
        }

        private var realtimeDualInputHistoryRecordingBinding: Binding<Bool> {
            Binding(
                get: { preferences.realtimeDualInputHistoryRecordingEnabled },
                set: { preferences.setRealtimeDualInputHistoryRecordingEnabled($0) }
            )
        }

        private var captionWindowModeBinding: Binding<RealtimeCaptionWindowMode> {
            Binding(
                get: { preferences.realtimeCaptionWindowMode },
                set: { preferences.setRealtimeCaptionWindowMode($0) }
            )
        }

        private var realtimeCaptionPrivacyBinding: Binding<Bool> {
            Binding(
                get: { preferences.realtimeCaptionPrivacyModeEnabled },
                set: { preferences.setRealtimeCaptionPrivacyModeEnabled($0) }
            )
        }

        private func addRealtimeLane() async {
            isAddingLane = true
            defer { isAddingLane = false }
            do {
                try await store.addDefaultLane()
            } catch {
                laneConfigurationError = error.localizedDescription
            }
        }

        private func handleAudioImport(_ result: Result<[URL], Error>) {
            do {
                let url = try result.get().first
                guard let url else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                _ = try AVAudioFile(forReading: url)
                store.setImportedAudioURL(url)
            } catch {
                guard (error as NSError).code != NSUserCancelledError else { return }
                audioImportError = error.localizedDescription
            }
        }

        private var startFailureAlertPresentedBinding: Binding<Bool> {
            Binding(
                get: { store.startFailureAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        store.dismissStartFailureAlert()
                    }
                }
            )
        }

        private func toggleRealtimeSession() async {
            guard !store.isStopping else { return }
            if store.isRunning {
                await store.toggleRunning()
                return
            }
            guard !isStartingRealtimeSession else { return }

            isStartingRealtimeSession = true
            defer {
                isStartingRealtimeSession = false
            }

            await store.start()
        }

        private func setFloatingCaptionsVisible(_ isVisible: Bool) {
            store.showCaptions = isVisible
            RealtimeFloatingCaptionWindowController.setVisible(isVisible, store: store)
            syncFloatingCaptionVisibility()
        }

        private func refreshFloatingCaptionWindowIfVisible() {
            guard RealtimeFloatingCaptionWindowController.isOpen else { return }
            RealtimeFloatingCaptionWindowController.open(store: store)
            syncFloatingCaptionVisibility()
        }

        private func syncFloatingCaptionVisibility() {
            isFloatingCaptionVisible = RealtimeFloatingCaptionWindowController.isOpen
            store.showCaptions = isFloatingCaptionVisible
        }
    }
#endif
