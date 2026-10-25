//
//  RealtimeOnboardingView.swift
//  TLingo
//
//  Realtime setup that runs inside first-run onboarding: pick languages, download
//  the Apple Translate pack, allow microphone / speech access, then try a live
//  session. `inputs` decides what the try step asks the user to do — speak into
//  the microphone, or capture audio playing on the iPhone — every other page is
//  shared. The session itself is the app's real `RealtimeSessionStore`.
//

#if os(iOS)
    import AVFoundation
    import Combine
    import os
    import ShareCore
    import Speech
    import SwiftUI
    import Translation
    import UIKit

    private let realtimeOnboardingLogger = os.Logger(
        subsystem: "com.zanderwang.AITranslator",
        category: "RealtimeOnboarding"
    )

    struct RealtimeOnboardingView: View {
        private enum Step: Int, CaseIterable {
            case intro
            case languages
            case download
            case permissions
            case tryIt
            case done
        }

        private enum PackState: Equatable {
            case unknown
            case ready
            case needsDownload
            case downloading
            case unsupported
        }

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.scenePhase) private var scenePhase
        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject private var store = RealtimeSessionStore.shared
        @StateObject private var controlModel = RealtimeControlModel()

        @State private var step: Step = .intro
        @State private var inputIndex = 0
        @State private var packState: PackState = .unknown
        @State private var downloadConfiguration: TranslationSession.Configuration?
        @State private var isSourcePickerPresented = false
        @State private var isTargetPickerPresented = false
        @State private var microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
        @State private var speechAuthorization = SFSpeechRecognizer.authorizationStatus()
        @State private var isRequestingPermissions = false
        @State private var originalInputSource: RealtimeAudioInputSource?
        @State private var showSkipOption = false
        @State private var hasPlayedSampleClip = false
        @StateObject private var sampleClipPlayer = OnboardingSampleClipPlayer()

        private let inputs: [OnboardingRealtimeInput]
        private let onBack: () -> Void
        private let onFinished: () -> Void

        /// - Parameters:
        ///   - inputs: The inputs to try, in order. Must not be empty.
        ///   - onBack: Leaves Realtime setup from its first page.
        ///   - onFinished: Called once Realtime setup is finished or skipped.
        init(
            inputs: [OnboardingRealtimeInput],
            onBack: @escaping () -> Void,
            onFinished: @escaping () -> Void
        ) {
            self.inputs = inputs.isEmpty ? [.microphone] : inputs
            self.onBack = onBack
            self.onFinished = onFinished
        }

        // MARK: - Derived state

        private var colors: AppColorPalette {
            AppColors.Palette(colorScheme: colorScheme, accentTheme: preferences.accentTheme)
        }

        private var currentInput: OnboardingRealtimeInput {
            inputs[min(inputIndex, inputs.count - 1)]
        }

        private var sourceLanguage: SourceLanguageOption {
            preferences.realtimeSourceLanguage
        }

        private var targetLanguage: TargetLanguageOption {
            preferences.realtimeTargetLanguage
        }

        private var languagePairKey: String {
            "\(sourceLanguage.rawValue)>\(targetLanguage.rawValue)"
        }

        private var isSameLanguage: Bool {
            LanguageDirectionSwap.isSameLanguage(source: sourceLanguage, target: targetLanguage)
        }

        private var usesMicrophone: Bool {
            inputs.contains(.microphone)
        }

        private var usesSpeechRecognition: Bool {
            inputs.contains(.iphoneAudio)
                || (usesMicrophone && preferences.realtimeRecognitionEngine.requiresSpeechRecognitionPermission)
        }

        private var deniedMicrophone: Bool {
            usesMicrophone && (microphoneAuthorization == .denied || microphoneAuthorization == .restricted)
        }

        private var deniedSpeechRecognition: Bool {
            usesSpeechRecognition && (speechAuthorization == .denied || speechAuthorization == .restricted)
        }

        private var permissionsDenied: Bool {
            deniedMicrophone || deniedSpeechRecognition
        }

        private var requiredAuthorizationsGranted: Bool {
            (!usesMicrophone || microphoneAuthorization == .authorized)
                && (!usesSpeechRecognition || speechAuthorization == .authorized)
        }

        private var hasCaption: Bool {
            store.captionLines.contains { $0.kind == .translation && !$0.isPending && !$0.text.isEmpty }
        }

        private var isSessionBusy: Bool {
            store.isRunning || store.isStopping || controlModel.isStartingRealtimeSession
        }

        private var availabilityStrategy: AppleTranslationAvailabilityStrategy {
            preferences.realtimeTranslationProvider == .appleTranslationRealtime ? .lowLatency : .automatic
        }

        private var unsupportedSourceLanguages: Set<SourceLanguageOption> {
            var models: [RecognitionModelDescriptor] = []
            if usesMicrophone {
                models.append(RecognitionModelStore.selectableDescriptor(forModelID: preferences.realtimeRecognitionModelID))
            }
            if inputs.contains(.iphoneAudio) {
                models.append(.appleSpeech)
            }
            return Set(SourceLanguageOption.realtimeSelectionOptions.filter { option in
                models.contains { !$0.supports(sourceLanguage: option) }
            })
        }

        // MARK: - Body

        var body: some View {
            ZStack {
                colors.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    pageContent

                    VStack(spacing: OnboardingMetrics.footerSpacing) {
                        footerControls
                        OnboardingProgressDots(total: Step.allCases.count, index: step.rawValue, colors: colors)
                    }
                    .padding(.horizontal, OnboardingMetrics.horizontalPadding)
                    .padding(.bottom, 8)
                }
            }
            .tint(colors.accent)
            .translationTask(downloadConfiguration) { session in
                await handleDownload(using: session)
            }
            .translationTask(store.appleTranslationDownloadConfiguration) { session in
                await store.prepareAppleTranslationLanguageDownload(using: session)
            }
            .overlay(alignment: .topLeading) {
                BroadcastPickerLauncher(trigger: $controlModel.broadcastPickerTrigger)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .accessibilityHidden(true)
            }
            .sheet(isPresented: $isSourcePickerPresented) {
                LanguagePickerView(
                    selectedCode: sourceCodeBinding,
                    isPresented: $isSourcePickerPresented,
                    rows: sourceLanguageRows,
                    title: String(localized: "Select Source Language")
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $isTargetPickerPresented) {
                LanguagePickerView(
                    selectedCode: targetCodeBinding,
                    isPresented: $isTargetPickerPresented,
                    rows: targetLanguageRows,
                    title: String(localized: "Select Target Language")
                )
                .presentationDetents([.medium, .large])
            }
            .alert(
                store.startFailureAlert?.title ?? String(localized: "Realtime Failed"),
                isPresented: startFailureAlertPresented
            ) {
                if store.startFailureAlert?.offersAppleTranslationDownload == true {
                    Button("Download") {
                        store.dismissStartFailureAlert()
                        store.allowAppleTranslationDownloadOnNextStart()
                        Task { await toggleSession() }
                    }
                }
                Button("OK", role: .cancel) {
                    store.dismissStartFailureAlert()
                }
            } message: {
                Text(store.startFailureAlert?.message ?? "")
            }
            .alert(
                controlModel.startBlockedAlert?.title ?? String(localized: "Cannot Start Realtime"),
                isPresented: startBlockedAlertPresented
            ) {
                if controlModel.startBlockedAlert?.opensAppSettings == true {
                    Button("Open Settings") {
                        openAppSettings()
                        controlModel.startBlockedAlert = nil
                    }
                }
                Button("OK", role: .cancel) {
                    controlModel.startBlockedAlert = nil
                }
            } message: {
                Text(controlModel.startBlockedAlert?.message ?? "")
            }
            .task(id: languagePairKey) {
                await refreshPackStatus()
            }
            .task(id: "\(step.rawValue)-\(inputIndex)") {
                guard step == .tryIt else { return }
                showSkipOption = false
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                showSkipOption = true
            }
            .onAppear(perform: prepare)
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                refreshPermissionStatus()
                if step == .permissions, requiredAuthorizationsGranted {
                    goTo(.tryIt)
                }
            }
            .onChange(of: step) { _, newStep in
                guard newStep == .tryIt else { return }
                beginTryStep()
            }
        }

        // MARK: - Pages

        @ViewBuilder
        private var pageContent: some View {
            switch step {
            case .intro:
                scrollingPage { introPage }
            case .languages:
                scrollingPage { languagesPage }
            case .download:
                scrollingPage { downloadPage }
            case .permissions:
                if permissionsDenied {
                    centeredPage { deniedPage }
                } else {
                    scrollingPage { permissionsPage }
                }
            case .tryIt:
                switch currentInput {
                case .microphone:
                    microphonePage
                case .iphoneAudio:
                    scrollingPage { capturePage }
                }
            case .done:
                centeredPage { donePage }
            }
        }

        private func scrollingPage(@ViewBuilder _ content: () -> some View) -> some View {
            ScrollView {
                content()
                    .padding(.horizontal, OnboardingMetrics.horizontalPadding)
                    .padding(.top, 32)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
        }

        private func centeredPage(@ViewBuilder _ content: () -> some View) -> some View {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                content()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, OnboardingMetrics.horizontalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }

        private func pageHeader(_ title: Text, _ subtitle: Text, titleSize: CGFloat = 28) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                title
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                subtitle
                    .font(.system(size: 15))
                    .foregroundStyle(colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        private func iconTile(_ systemName: String) -> some View {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(colors.accent)
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colors.chipSecondaryBackground)
                )
        }

        // MARK: Intro

        private var introPage: some View {
            VStack(alignment: .leading, spacing: 28) {
                captionPreviewCard
                pageHeader(
                    Text("Read what you hear, as it happens"),
                    Text(
                        "Realtime shows bilingual captions while people speak. Apple Translate does the translating on your iPhone."
                    ),
                    titleSize: 32
                )
            }
        }

        /// Illustrative captions only; the sample pair is not localized.
        private var captionPreviewCard: some View {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    HStack(spacing: 6) {
                        Text(verbatim: "English")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text(verbatim: "简体中文")
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(colors.chipSecondaryBackground))
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        ForEach([8, 16, 11, 18, 6] as [CGFloat], id: \.self) { height in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(colors.accent)
                                .frame(width: 3, height: height)
                        }
                    }
                    .frame(height: 20)
                }
                samplePair(source: "Excuse me, is this seat taken?", translation: "打扰一下，这个座位有人吗？")
                samplePair(source: "No, please go ahead.", translation: "没有，请坐。")
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: "Are you heading downtown…")
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colors.skeleton)
                        .frame(width: 220, height: 10)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(colors.skeleton)
                        .frame(width: 130, height: 10)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colors.cardBackground)
            )
            .accessibilityHidden(true)
        }

        private func samplePair(source: String, translation: String) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: source)
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
                Text(verbatim: translation)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(colors.textPrimary)
            }
        }

        // MARK: Languages

        private var languagesPage: some View {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(
                    Text("Choose your languages"),
                    Text("Pick the language you will hear and the one you want captions in.")
                )
                languageCard
                packStatusRow
            }
        }

        private var languageCard: some View {
            ZStack {
                VStack(spacing: 0) {
                    languageRow(
                        label: "Spoken language:",
                        value: sourceLanguage.primaryLabel,
                        identifier: "onboarding_realtime_source_language"
                    ) { isSourcePickerPresented = true }

                    Rectangle()
                        .fill(colors.divider)
                        .frame(height: 1)
                        .padding(.horizontal, 16)

                    languageRow(
                        label: "Target language:",
                        value: targetLanguage.primaryLabel,
                        identifier: "onboarding_realtime_target_language"
                    ) { isTargetPickerPresented = true }
                }

                Button(action: swapLanguages) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canSwapLanguages ? colors.accent : colors.textSecondary.opacity(0.4))
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(colors.chipSecondaryBackground))
                        .overlay(Circle().stroke(colors.cardBackground, lineWidth: 4))
                }
                .buttonStyle(.plain)
                .disabled(!canSwapLanguages)
                .accessibilityLabel(Text("Swap languages"))
                .accessibilityIdentifier("onboarding_realtime_swap_languages")
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(colors.cardBackground)
            )
        }

        private func languageRow(
            label: LocalizedStringKey,
            value: String,
            identifier: String,
            action: @escaping () -> Void
        ) -> some View {
            Button(action: action) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(colors.accent)
                        Text(verbatim: value)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(colors.textPrimary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.textSecondary)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        }

        private var packStatusRow: some View {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: packStatusIcon)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(packStatusIconColor)
                    .frame(width: 36, height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(colors.chipSecondaryBackground)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    packStatusTitle
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    packStatusDetail
                        .font(.system(size: 13))
                        .foregroundStyle(colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }

        private var packStatusIcon: String {
            if isSameLanguage || packState == .unsupported {
                return "exclamationmark.triangle"
            }
            return packState == .ready ? "checkmark.circle.fill" : "arrow.down.circle"
        }

        private var packStatusIconColor: Color {
            if isSameLanguage || packState == .unsupported {
                return colors.error
            }
            return packState == .ready ? colors.success : colors.accent
        }

        private var packStatusTitle: Text {
            if isSameLanguage {
                return Text("Choose two different languages")
            }
            switch packState {
            case .unsupported: return Text("Pair not supported")
            case .ready: return Text("Languages installed")
            default: return Text("Download needed")
            }
        }

        private var packStatusDetail: Text {
            let source = sourceLanguage.primaryLabel
            let target = targetLanguage.primaryLabel
            if isSameLanguage {
                return Text("Realtime translates from one language into another.")
            }
            switch packState {
            case .unsupported:
                return Text("Apple Translate does not support \(source) to \(target). Pick another pair.")
            case .ready:
                return Text("Apple Translate translates \(source) and \(target) on your iPhone.")
            default:
                return Text("Apple Translate downloads \(source) and \(target) once. iOS asks you to approve it next.")
            }
        }

        // MARK: Download

        private var downloadPage: some View {
            VStack(alignment: .leading, spacing: 28) {
                switch packState {
                case .ready:
                    pageHeader(
                        Text("Languages are ready"),
                        Text(
                            "\(sourceLanguage.primaryLabel) and \(targetLanguage.primaryLabel) are installed. Apple Translate now translates on your iPhone."
                        )
                    )
                case .downloading:
                    pageHeader(
                        Text("Approve the download"),
                        Text("iOS is asking to download these languages for Apple Translate. Tap Download in the prompt.")
                    )
                default:
                    pageHeader(
                        Text("The download did not finish"),
                        Text("Realtime needs these languages before it can translate. Try again when you are ready.")
                    )
                }
                languagePairCard
            }
        }

        private var languagePairCard: some View {
            HStack(spacing: 12) {
                iconTile("globe")
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(sourceLanguage.primaryLabel) → \(targetLanguage.primaryLabel)")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    switch packState {
                    case .ready:
                        Text("Downloaded")
                    case .downloading:
                        Text("Waiting for approval")
                    default:
                        Text("Not downloaded")
                    }
                }
                .font(.system(size: 13))
                .foregroundStyle(colors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)

                switch packState {
                case .ready:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(colors.success)
                        .accessibilityLabel(Text("Downloaded"))
                case .downloading:
                    ProgressView()
                default:
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 22))
                        .foregroundStyle(colors.textSecondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .onboardingCardBackground(colors: colors)
        }

        // MARK: Permissions

        private var permissionsPage: some View {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(
                    Text("Let TLingo hear speech"),
                    usesMicrophone && usesSpeechRecognition
                        ? Text("Realtime needs two permissions to turn speech into captions. iOS asks for each one.")
                        : Text("Realtime needs this permission to turn speech into captions. iOS asks for it.")
                )

                VStack(spacing: 0) {
                    if usesMicrophone {
                        permissionRow(
                            icon: "mic.fill",
                            title: "Microphone",
                            detail: "Picks up the speech around you.",
                            isGranted: microphoneAuthorization == .authorized
                        )
                    }
                    if usesMicrophone, usesSpeechRecognition {
                        Rectangle()
                            .fill(colors.divider)
                            .frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                    if usesSpeechRecognition {
                        permissionRow(
                            icon: "waveform",
                            title: "Speech Recognition",
                            detail: "Turns what it hears into text.",
                            isGranted: speechAuthorization == .authorized
                        )
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colors.cardBackground)
                )

                Text("You can change these later in Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(colors.textSecondary)
                    .padding(.horizontal, 4)
            }
        }

        private func permissionRow(
            icon: String,
            title: LocalizedStringKey,
            detail: LocalizedStringKey,
            isGranted: Bool
        ) -> some View {
            HStack(spacing: 12) {
                iconTile(icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(colors.textPrimary)
                    Text(detail)
                        .font(.system(size: 14))
                        .foregroundStyle(colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(colors.success)
                        .accessibilityLabel(Text("Allowed"))
                }
            }
            .padding(16)
        }

        private var deniedPage: some View {
            VStack(spacing: 24) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(colors.error)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(colors.error.opacity(0.10)))
                    .overlay(Circle().stroke(colors.error.opacity(0.3), lineWidth: 1))

                VStack(spacing: 8) {
                    (deniedMicrophone ? Text("Microphone access is off") : Text("Speech Recognition access is off"))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(colors.textPrimary)
                    Text("Realtime cannot hear anything until you turn it on for TLingo in Settings.")
                        .font(.system(size: 15))
                        .foregroundStyle(colors.textSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    if usesMicrophone {
                        deniedStatusRow(title: "Microphone", isOn: microphoneAuthorization == .authorized)
                    }
                    if usesMicrophone, usesSpeechRecognition {
                        Rectangle()
                            .fill(colors.divider)
                            .frame(height: 1)
                            .padding(.horizontal, 16)
                    }
                    if usesSpeechRecognition {
                        deniedStatusRow(title: "Speech Recognition", isOn: speechAuthorization == .authorized)
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colors.cardBackground)
                )
            }
        }

        private func deniedStatusRow(title: LocalizedStringKey, isOn: Bool) -> some View {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Image(systemName: isOn ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(isOn ? colors.success : colors.error)
                    if isOn {
                        Text("On")
                    } else {
                        Text("Off")
                    }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(colors.textPrimary)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
        }

        // MARK: Try: microphone

        private var microphonePage: some View {
            VStack(alignment: .leading, spacing: 20) {
                pageHeader(
                    Text("Say a few sentences"),
                    Text("Speak in \(sourceLanguage.primaryLabel). Your words and their translation appear below.")
                )

                if let phrase = OnboardingPracticePhrase.phrase(for: sourceLanguage) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Try saying:")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(colors.accent)
                        Text(verbatim: "“\(phrase)”")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(colors.chipSecondaryBackground)
                    )
                }

                captionCard
            }
            .padding(.horizontal, OnboardingMetrics.horizontalPadding)
            .padding(.top, 32)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }

        private var captionCard: some View {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(store.captionLines) { line in
                            captionText(line)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .overlay {
                    if store.captionLines.isEmpty {
                        Text(store.isRunning ? "Listening…" : "Tap the microphone and start speaking.")
                            .font(.system(size: 14))
                            .foregroundStyle(colors.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }

                HStack {
                    HStack(spacing: 10) {
                        RealtimeInputLevelIndicator(
                            level: store.inputLevel,
                            isActive: store.isRunning && !store.isPaused,
                            tint: colors.accent,
                            barWidth: 3,
                            maxHeight: 24
                        )
                        if store.isRunning {
                            Text("Listening")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(colors.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        Task { await toggleSession() }
                    } label: {
                        Image(systemName: store.isRunning ? "stop.fill" : "mic.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(colors.onAccent)
                            .frame(width: 48, height: 48)
                            .background(Circle().fill(store.isRunning ? colors.error : colors.accentFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(controlModel.isStartingRealtimeSession || store.isStopping)
                    .accessibilityLabel(store.isRunning ? Text("Stop listening") : Text("Start listening"))
                    .accessibilityIdentifier("onboarding_realtime_session_button")
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 200, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(colors.cardBackground)
            )
        }

        private func captionText(_ line: RealtimeCaptionLine) -> some View {
            let isTranslation = line.kind == .translation
            return Text(verbatim: line.text)
                .font(isTranslation ? .system(size: 17, weight: .semibold) : .system(size: 13))
                .foregroundStyle(isTranslation ? colors.textPrimary : colors.textSecondary)
                .opacity(line.isPending ? 0.6 : 1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }

        // MARK: Try: capture iPhone audio

        private enum CaptureStage: Int {
            case startCapture = 1
            case waitForCapture
            case playClip
            case watchCaptions
        }

        private var isCapturingIPhoneAudio: Bool {
            store.isRunning && store.inputSource == .iphoneAudio
        }

        /// The broadcast is accepted seconds before the extension can recognize audio; a clip played earlier is lost.
        private var isCaptureReady: Bool {
            isCapturingIPhoneAudio && store.isIPhoneAudioCaptureReady
        }

        private var captureStage: CaptureStage {
            if !isCapturingIPhoneAudio, !hasCaption { return .startCapture }
            if !isCaptureReady, !hasPlayedSampleClip, !hasCaption { return .waitForCapture }
            if !hasPlayedSampleClip, !hasCaption { return .playClip }
            return .watchCaptions
        }

        private static let sampleClipPhrase = "Where were you last night?"

        private var capturePage: some View {
            VStack(alignment: .leading, spacing: 24) {
                pageHeader(
                    Text("Caption what you watch"),
                    Text("TLingo listens to audio playing on your iPhone, so it does not need the microphone.")
                )

                sampleClip

                VStack(alignment: .leading, spacing: 14) {
                    captureStep(.startCapture, "Tap Start capture, choose TLingo, then tap Start Broadcast.")
                    captureStep(.waitForCapture, "Wait a moment while capture gets ready.")
                    captureStep(.playClip, "Tap play on the clip above.")
                    captureStep(.watchCaptions, "Watch the captions appear on the clip.")
                    if hasCaption {
                        Text("Captions keep running in other apps too. Play any video to try it.")
                            .font(.system(size: 13))
                            .foregroundStyle(colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .transition(.opacity)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onboardingCardBackground(colors: colors)
                .animation(.easeInOut(duration: 0.2), value: captureStage)
                .animation(.easeInOut(duration: 0.2), value: hasCaption)
            }
            .onDisappear { sampleClipPlayer.stop() }
        }

        /// A stand-in video whose play button speaks a line, so the capture can be tried without leaving TLingo.
        private var sampleClip: some View {
            let canPlay = isCaptureReady && !sampleClipPlayer.isPlaying
            return ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    // The frame stands in for video, so it stays dark in both appearances.
                    .fill(AppColors.Palette(colorScheme: .light, accentTheme: preferences.accentTheme).textPrimary)
                Button {
                    hasPlayedSampleClip = true
                    sampleClipPlayer.speak(Self.sampleClipPhrase, languageCode: "en-US")
                } label: {
                    Image(systemName: sampleClipPlayer.isPlaying ? "waveform" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative, isActive: sampleClipPlayer.isPlaying)
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(.white.opacity(canPlay ? 0.24 : 0.12)))
                        .overlay {
                            if captureStage == .playClip {
                                Circle().stroke(colors.accent, lineWidth: 2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .disabled(!canPlay)
                .opacity(isCaptureReady ? 1 : 0.5)
                .frame(maxHeight: .infinity)
                .accessibilityLabel(Text("Play sample clip"))
                .accessibilityIdentifier("onboarding_realtime_play_sample")

                sampleClipCaption
                    .shadow(color: .black.opacity(0.5), radius: 3, y: 1)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
            }
            .frame(height: 197)
        }

        /// The latest recognized line and its translation, straight from the running session.
        @ViewBuilder
        private var sampleClipCaption: some View {
            let source = store.captionLines.last { $0.kind == .source && !$0.text.isEmpty }
            let translation = store.captionLines.last { $0.kind == .translation && !$0.text.isEmpty }
            VStack(spacing: 2) {
                if source == nil, translation == nil {
                    Group {
                        if isCaptureReady {
                            Text("Captions appear here")
                        } else if isCapturingIPhoneAudio {
                            Text("Getting capture ready…")
                        } else {
                            Text("Start capture to play the clip")
                        }
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                } else {
                    if let source {
                        Text(verbatim: source.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    if let translation {
                        Text(verbatim: translation.text)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .opacity(translation.isPending ? 0.7 : 1)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
        }

        private func captureStep(_ stage: CaptureStage, _ text: LocalizedStringKey) -> some View {
            let isDone = stage.rawValue < captureStage.rawValue || (stage == .watchCaptions && hasCaption)
            let isCurrent = stage == captureStage && !isDone
            return HStack(spacing: 12) {
                Group {
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                    } else if isCurrent, stage == .waitForCapture {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(colors.onAccent)
                    } else {
                        Text(verbatim: "\(stage.rawValue)")
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .foregroundStyle(isDone || isCurrent ? colors.onAccent : colors.textSecondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(
                        isDone ? colors.success : (isCurrent ? colors.accentFill : colors.chipSecondaryBackground)
                    )
                )
                Text(text)
                    .font(.system(size: 15, weight: isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent || isDone ? colors.textPrimary : colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }

        private var tryStatusRow: some View {
            HStack(spacing: 8) {
                Image(systemName: hasCaption ? "checkmark.circle.fill" : "clock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(hasCaption ? colors.success : colors.textSecondary)
                if hasCaption {
                    Text("Captions are working.")
                } else if currentInput == .iphoneAudio {
                    Text("Waiting for audio…")
                } else if store.isRunning || controlModel.isStartingRealtimeSession {
                    Text(verbatim: store.statusText)
                } else {
                    Text("Waiting for you to speak…")
                }
                if !hasCaption, showSkipOption {
                    Button("Skip for now") {
                        continueFromTryStep()
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(hasCaption ? colors.textPrimary : colors.textSecondary)
        }

        // MARK: Done

        private var donePage: some View {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(colors.success)
                    .frame(width: 96, height: 96)
                    .background(Circle().fill(colors.success.opacity(0.14)))
                    .overlay(Circle().stroke(colors.success.opacity(0.3), lineWidth: 1))
                    .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("Realtime is ready")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(colors.textPrimary)
                    Text("Open the Realtime tab any time to start captions.")
                        .font(.system(size: 15))
                        .foregroundStyle(colors.textSecondary)
                }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 0) {
                    summaryRow(
                        title: "Languages",
                        value: "\(sourceLanguage.primaryLabel) → \(targetLanguage.primaryLabel)"
                    )
                    Rectangle().fill(colors.divider).frame(height: 1).padding(.horizontal, 16)
                    summaryRow(title: "Input", value: inputsSummary)
                    Rectangle().fill(colors.divider).frame(height: 1).padding(.horizontal, 16)
                    summaryRow(title: "Translation", value: String(localized: "Apple Translate"))
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(colors.cardBackground)
                )
            }
        }

        private var inputsSummary: String {
            inputs.map { $0.realtimeSource.title }.joined(separator: ", ")
        }

        private func summaryRow(title: LocalizedStringKey, value: String) -> some View {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(colors.textSecondary)
                Spacer(minLength: 0)
                Text(verbatim: value)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(colors.textPrimary)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
        }

        // MARK: - Footer

        @ViewBuilder
        private var footerControls: some View {
            switch step {
            case .intro:
                OnboardingPrimaryButton(title: "Set up Realtime", colors: colors) { goTo(.languages) }
                    .accessibilityIdentifier("onboarding_realtime_setup")
                OnboardingSecondaryButton(title: "Back", colors: colors) { leave(then: onBack) }

            case .languages:
                let title: LocalizedStringKey = packState == .ready ? "Continue" : "Download languages"
                OnboardingPrimaryButton(
                    title: title,
                    colors: colors,
                    isDisabled: isSameLanguage || packState == .unsupported
                ) { continueFromLanguages() }
                    .accessibilityIdentifier("onboarding_realtime_languages_continue")
                OnboardingSecondaryButton(title: "Back", colors: colors) { goTo(.intro) }

            case .download:
                downloadFooter

            case .permissions:
                permissionsFooter

            case .tryIt:
                tryFooter

            case .done:
                OnboardingPrimaryButton(title: "Start translating", colors: colors) { finish() }
                    .accessibilityIdentifier("onboarding_realtime_finish")
                Color.clear.frame(height: OnboardingMetrics.secondaryButtonHeight)
            }
        }

        @ViewBuilder
        private var downloadFooter: some View {
            switch packState {
            case .ready:
                OnboardingPrimaryButton(title: "Continue", colors: colors) { goTo(.permissions) }
                OnboardingSecondaryButton(title: "Change languages", colors: colors) { goTo(.languages) }
            case .downloading:
                OnboardingPrimaryButton(title: "Continue", colors: colors, isDisabled: true) {}
                OnboardingSecondaryButton(title: "Back", colors: colors) { goTo(.languages) }
            default:
                OnboardingPrimaryButton(title: "Try again", colors: colors) { requestDownload() }
                OnboardingSecondaryButton(title: "Back", colors: colors) { goTo(.languages) }
            }
        }

        @ViewBuilder
        private var permissionsFooter: some View {
            if permissionsDenied {
                OnboardingPrimaryButton(title: "Open Settings", colors: colors) { openAppSettings() }
                OnboardingSecondaryButton(title: "Skip Realtime for now", colors: colors) { finish() }
            } else if requiredAuthorizationsGranted {
                OnboardingPrimaryButton(title: "Continue", colors: colors) { goTo(.tryIt) }
                OnboardingSecondaryButton(title: "Back", colors: colors) { goTo(.languages) }
            } else {
                OnboardingPrimaryButton(title: "Allow access", colors: colors, isDisabled: isRequestingPermissions) {
                    Task { await requestPermissions() }
                }
                .accessibilityIdentifier("onboarding_realtime_allow_access")
                OnboardingSecondaryButton(title: "Back", colors: colors) { goTo(.languages) }
            }
        }

        @ViewBuilder
        private var tryFooter: some View {
            tryStatusRow
            switch currentInput {
            case .microphone:
                OnboardingPrimaryButton(title: "Continue", colors: colors, isDisabled: !hasCaption) {
                    continueFromTryStep()
                }
                .accessibilityIdentifier("onboarding_realtime_try_continue")
            case .iphoneAudio:
                if hasCaption {
                    OnboardingPrimaryButton(title: "Continue", colors: colors) { continueFromTryStep() }
                        .accessibilityIdentifier("onboarding_realtime_try_continue")
                } else if isSessionBusy {
                    OnboardingPrimaryButton(title: "Continue", colors: colors, isDisabled: true) {}
                } else {
                    OnboardingPrimaryButton(title: "Start capture", colors: colors) {
                        Task { await toggleSession() }
                    }
                    .accessibilityIdentifier("onboarding_realtime_start_capture")
                }
            }
            OnboardingSecondaryButton(title: "Back", colors: colors) { backFromTryStep() }
        }

        // MARK: - Actions

        private func goTo(_ newStep: Step) {
            withAnimation(.easeInOut(duration: OnboardingMetrics.stepTransition)) {
                step = newStep
            }
        }

        private func prepare() {
            if originalInputSource == nil {
                originalInputSource = store.inputSource
            }
            // Onboarding starts from English into the app language (or the next non-English system language).
            preferences.setRealtimeSourceLanguage(.english, reason: "RealtimeOnboarding.prepare")
            preferences.setRealtimeTargetLanguage(
                TargetLanguageOption.defaultRealtimeTargetLanguage(),
                reason: "RealtimeOnboarding.prepare"
            )
            if preferences.realtimeTranslationProvider == .transcriptionOnly {
                preferences.setRealtimeTranslationProvider(.appleTranslator)
            }
            // Onboarding only offers the built-in recognizer; downloadable models stay in Settings.
            preferences.setRealtimeRecognitionModelID(RecognitionModelDescriptor.appleSpeech.id)
            store.languageSelectionDidChange()
            refreshPermissionStatus()
        }

        private func applyCurrentInput() {
            store.inputSource = currentInput.realtimeSource
            if currentInput == .iphoneAudio {
                controlModel.enforceIPhoneAudioLocalRoute(store: store, preferences: preferences)
            }
        }

        private func beginTryStep() {
            if !store.isRunning {
                store.resetTranscript()
            }
            hasPlayedSampleClip = false
            applyCurrentInput()
        }

        private func refreshPermissionStatus() {
            microphoneAuthorization = AVCaptureDevice.authorizationStatus(for: .audio)
            speechAuthorization = SFSpeechRecognizer.authorizationStatus()
        }

        private func requestPermissions() async {
            guard !isRequestingPermissions else { return }
            isRequestingPermissions = true
            defer { isRequestingPermissions = false }

            if usesMicrophone, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
            if usesSpeechRecognition {
                _ = await RealtimeIPhoneAudioPreflight.requestSpeechAuthorizationIfNeeded()
            }
            refreshPermissionStatus()
            if requiredAuthorizationsGranted {
                goTo(.tryIt)
            }
        }

        private func openAppSettings() {
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        }

        // MARK: Languages

        private var sourceLanguageRows: [LanguageRow] {
            let unsupported = unsupportedSourceLanguages
            return SourceLanguageOption.realtimeSelectionOptions.map {
                LanguageRow(
                    source: $0,
                    disabledReason: unsupported.contains($0)
                        ? String(localized: "Not supported by selected recognition model")
                        : nil
                )
            }
        }

        private var targetLanguageRows: [LanguageRow] {
            TargetLanguageOption.realtimeSelectionOptions.map { LanguageRow(target: $0) }
        }

        private var sourceCodeBinding: Binding<String> {
            Binding(
                get: { preferences.realtimeSourceLanguage.rawValue },
                set: { code in
                    guard let option = SourceLanguageOption(rawValue: code), option != .auto else { return }
                    preferences.setRealtimeSourceLanguage(option, reason: "RealtimeOnboarding.picker")
                    store.languageSelectionDidChange()
                }
            )
        }

        private var targetCodeBinding: Binding<String> {
            Binding(
                get: { preferences.realtimeTargetLanguage.rawValue },
                set: { code in
                    guard let option = TargetLanguageOption(rawValue: code), option != .appLanguage else { return }
                    preferences.setRealtimeTargetLanguage(option, reason: "RealtimeOnboarding.picker")
                    store.languageSelectionDidChange()
                }
            )
        }

        private var swappedDirection: LanguageDirectionSwap.Result? {
            guard sourceLanguage != .auto, targetLanguage != .appLanguage else { return nil }
            let swapped = LanguageDirectionSwap.swapped(source: sourceLanguage, target: targetLanguage)
            guard SourceLanguageOption.realtimeSelectionOptions.contains(swapped.source),
                  TargetLanguageOption.realtimeSelectionOptions.contains(swapped.target),
                  !unsupportedSourceLanguages.contains(swapped.source)
            else { return nil }
            return swapped
        }

        private var canSwapLanguages: Bool {
            swappedDirection != nil
        }

        private func swapLanguages() {
            guard let swapped = swappedDirection else { return }
            preferences.setRealtimeSourceLanguage(swapped.source, reason: "RealtimeOnboarding.swap")
            preferences.setRealtimeTargetLanguage(swapped.target, reason: "RealtimeOnboarding.swap")
            store.languageSelectionDidChange()
        }

        // MARK: Apple Translate pack

        private func continueFromLanguages() {
            if packState == .ready {
                goTo(.permissions)
            } else {
                goTo(.download)
                requestDownload()
            }
        }

        private func refreshPackStatus() async {
            guard !isSameLanguage, let source = sourceLanguage.localeLanguage else {
                packState = .unknown
                return
            }
            do {
                let status = try await AppleTranslationService.shared.languageAvailabilityStatus(
                    source: source,
                    target: targetLanguage.localeLanguage,
                    strategy: availabilityStrategy
                )
                switch status {
                case .installed: packState = .ready
                case .supported: packState = .needsDownload
                case .unsupported: packState = .unsupported
                @unknown default: packState = .unknown
                }
            } catch {
                realtimeOnboardingLogger.error("pack status failed: \(String(describing: error), privacy: .public)")
                packState = .unknown
            }
        }

        private func makeDownloadConfiguration() -> TranslationSession.Configuration? {
            guard let source = sourceLanguage.localeLanguage else { return nil }
            let target = targetLanguage.localeLanguage
            if #available(iOS 26.4, *), availabilityStrategy == .lowLatency {
                return .init(source: source, target: target, preferredStrategy: .lowLatency)
            }
            return .init(source: source, target: target)
        }

        private func requestDownload() {
            guard var configuration = makeDownloadConfiguration() else { return }
            // An unchanged configuration does not re-run the task; invalidate it to show the prompt again.
            if var previous = downloadConfiguration,
               previous.source == configuration.source,
               previous.target == configuration.target
            {
                previous.invalidate()
                configuration = previous
            }
            packState = .downloading
            downloadConfiguration = configuration
        }

        private func handleDownload(using session: TranslationSession) async {
            do {
                try await session.prepareTranslation()
            } catch {
                realtimeOnboardingLogger.error("prepareTranslation failed: \(String(describing: error), privacy: .public)")
            }
            await refreshPackStatus()
            if packState != .ready, packState != .unsupported {
                packState = .needsDownload
            }
        }

        // MARK: Session

        private func toggleSession() async {
            applyCurrentInput()
            await controlModel.handleStartButtonTapped(store: store, preferences: preferences)
        }

        private func stopSessionIfNeeded() async {
            if store.isRunning {
                await store.stop()
            }
        }

        private func continueFromTryStep() {
            Task {
                await stopSessionIfNeeded()
                if inputIndex + 1 < inputs.count {
                    inputIndex += 1
                    beginTryStep()
                } else {
                    goTo(.done)
                }
            }
        }

        private func backFromTryStep() {
            Task {
                await stopSessionIfNeeded()
                if inputIndex > 0 {
                    inputIndex -= 1
                    beginTryStep()
                } else {
                    goTo(.permissions)
                }
            }
        }

        private func finish() {
            leave(then: onFinished)
        }

        /// Going back to the scenario picker also restores the input source, so re-entering captures the user's own.
        private func leave(then completion: @escaping () -> Void) {
            Task {
                await stopSessionIfNeeded()
                if !store.captionLines.isEmpty {
                    store.resetTranscript()
                }
                if let originalInputSource {
                    store.inputSource = originalInputSource
                }
                completion()
            }
        }

        private var startFailureAlertPresented: Binding<Bool> {
            Binding(
                get: { store.startFailureAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        store.dismissStartFailureAlert()
                    }
                }
            )
        }

        private var startBlockedAlertPresented: Binding<Bool> {
            Binding(
                get: { controlModel.startBlockedAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        controlModel.startBlockedAlert = nil
                    }
                }
            )
        }
    }

    private extension OnboardingRealtimeInput {
        var realtimeSource: RealtimeAudioInputSource {
            switch self {
            case .microphone: .microphone
            case .iphoneAudio: .iphoneAudio
            }
        }
    }

    /// Speaks the sample clip through the app's audio output, which the broadcast extension captures.
    @MainActor
    private final class OnboardingSampleClipPlayer: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
        @Published private(set) var isPlaying = false
        private let synthesizer = AVSpeechSynthesizer()

        override init() {
            super.init()
            synthesizer.delegate = self
        }

        func speak(_ text: String, languageCode: String) {
            // Playback ignores the ring/silent switch, so the capture still hears the clip.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: languageCode)
            synthesizer.stopSpeaking(at: .immediate)
            synthesizer.speak(utterance)
            isPlaying = true
        }

        func stop() {
            synthesizer.stopSpeaking(at: .immediate)
            isPlaying = false
        }

        nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
            Task { @MainActor in self.isPlaying = false }
        }

        nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
            Task { @MainActor in self.isPlaying = false }
        }
    }
#endif
