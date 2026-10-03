#if os(macOS)
    import AppKit
    import AVFoundation
    import Combine
    import CoreGraphics
    #if DIRECT_DISTRIBUTION
        import PermissionFlow
    #endif
    import Speech

    enum RealtimePermissionState {
        case unknown
        case notDetermined
        case granted
        case denied

        var isGranted: Bool {
            self == .granted
        }
    }

    enum RealtimePermissionKind {
        case speechRecognition
        case microphone
        case screenAndSystemAudio
    }

    @MainActor
    final class RealtimePermissionManager: ObservableObject {
        @Published private(set) var speechRecognition: RealtimePermissionState = .unknown
        @Published private(set) var microphone: RealtimePermissionState = .unknown
        @Published private(set) var screenAndSystemAudio: RealtimePermissionState = .unknown
        @Published private(set) var hasRequestedInitialPermissions = false

        private var pollTimer: Timer?
        #if DIRECT_DISTRIBUTION
            private var permissionFlow: PermissionFlowController?
        #endif

        var allGranted: Bool {
            speechRecognition.isGranted && microphone.isGranted && screenAndSystemAudio.isGranted
        }

        init() {
            refresh()
        }

        deinit {
            pollTimer?.invalidate()
        }

        func requestInitialPermissionsIfNeeded() async {
            guard !hasRequestedInitialPermissions else {
                openFirstMissingSettings()
                return
            }

            hasRequestedInitialPermissions = true

            await requestSpeechRecognitionIfNeeded()
            await requestMicrophoneIfNeeded()
            refresh()
            if !allGranted {
                openFirstMissingSettings()
            }
        }

        func refresh() {
            let newSpeechRecognition = Self.speechRecognitionState()
            let newMicrophone = Self.microphoneState()
            let newScreenAndSystemAudio: RealtimePermissionState = CGPreflightScreenCaptureAccess()
                ? .granted
                : (hasRequestedInitialPermissions ? .denied : .notDetermined)
            #if DIRECT_DISTRIBUTION
                let screenAndSystemAudioWasGranted = screenAndSystemAudio.isGranted
            #endif

            // Avoid no-op @Published writes — the 1.5s poll fires unconditionally and
            // every write triggers SwiftUI re-renders even when nothing changed.
            if speechRecognition != newSpeechRecognition {
                speechRecognition = newSpeechRecognition
            }
            if microphone != newMicrophone {
                microphone = newMicrophone
            }
            if screenAndSystemAudio != newScreenAndSystemAudio {
                screenAndSystemAudio = newScreenAndSystemAudio
            }

            #if DIRECT_DISTRIBUTION
                if newScreenAndSystemAudio.isGranted, !screenAndSystemAudioWasGranted {
                    permissionFlow?.closePanel(returnToPreviousApp: true)
                    permissionFlow = nil
                }
            #endif

            if allGranted {
                pollTimer?.invalidate()
                pollTimer = nil
            }
        }

        func startPolling() {
            guard pollTimer == nil else { return }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }

        func stopPolling() {
            pollTimer?.invalidate()
            pollTimer = nil
            #if DIRECT_DISTRIBUTION
                permissionFlow?.closePanel()
                permissionFlow = nil
            #endif
        }

        func openFirstMissingSettings() {
            refresh()

            if !screenAndSystemAudio.isGranted {
                openSettings(for: .screenAndSystemAudio)
            } else if !microphone.isGranted {
                openSettings(for: .microphone)
            } else if !speechRecognition.isGranted {
                openSettings(for: .speechRecognition)
            } else {
                openPrivacyPane("Privacy")
            }
            startPolling()
        }

        private func openSettings(for kind: RealtimePermissionKind) {
            switch kind {
            case .speechRecognition:
                openPrivacyPane("Privacy_SpeechRecognition")
            case .microphone:
                openPrivacyPane("Privacy_Microphone")
            case .screenAndSystemAudio:
                #if DIRECT_DISTRIBUTION
                    permissionFlow = permissionFlow ?? PermissionFlowController(
                        configuration: .init(promptForAccessibilityTrust: false)
                    )
                    permissionFlow?.authorize(
                        pane: .screenRecording,
                        suggestedAppURLs: [Bundle.main.bundleURL]
                    )
                #else
                    openPrivacyPane("Privacy_ScreenCapture")
                #endif
            }
        }

        private func requestMicrophoneIfNeeded() async {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        private func requestSpeechRecognitionIfNeeded() async {
            guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return }

            _ = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
        }

        private func openPrivacyPane(_ pane: String) {
            guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
            NSWorkspace.shared.open(url)
        }

        private static func microphoneState() -> RealtimePermissionState {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied, .restricted:
                return .denied
            @unknown default:
                return .unknown
            }
        }

        private static func speechRecognitionState() -> RealtimePermissionState {
            switch SFSpeechRecognizer.authorizationStatus() {
            case .authorized:
                return .granted
            case .notDetermined:
                return .notDetermined
            case .denied, .restricted:
                return .denied
            @unknown default:
                return .unknown
            }
        }
    }
#endif
