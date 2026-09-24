#if os(macOS) || os(iOS)
    import Foundation

    public enum RealtimeAudioInputSource: String, CaseIterable, Identifiable {
        #if os(macOS)
            case macAudio
        #endif
        case microphone
        #if os(iOS)
            case iphoneAudio
        #endif

        public static var allCases: [RealtimeAudioInputSource] {
            #if os(macOS)
                return [.macAudio, .microphone]
            #else
                // iPhone Audio realtime input is temporarily disabled pending
                // further work. Restore `.iphoneAudio` here to re-enable it.
                return [.microphone]
            #endif
        }

        public static var `default`: RealtimeAudioInputSource {
            #if os(macOS)
                return .macAudio
            #else
                return .microphone
            #endif
        }

        public var id: String { rawValue }

        public var title: String {
            switch self {
            #if os(macOS)
                case .macAudio:
                    return String(localized: "Mac Audio")
            #endif
            case .microphone:
                return String(localized: "Microphone")
            #if os(iOS)
                case .iphoneAudio:
                    return String(localized: "iPhone Audio")
            #endif
            }
        }

        public var systemImage: String {
            switch self {
            #if os(macOS)
                case .macAudio:
                    return "speaker.wave.2.fill"
            #endif
            case .microphone:
                return "mic.fill"
            #if os(iOS)
                case .iphoneAudio:
                    return "iphone.radiowaves.left.and.right"
            #endif
            }
        }

        public var supportedTranslationProviders: [RealtimeTranslationProvider] {
            switch self {
            #if os(iOS)
                case .iphoneAudio:
                    return [.appleTranslator]
            #endif
            default:
                return RealtimeTranslationProvider.availableCases
            }
        }

        public var supportedRecognitionModels: [RecognitionModelDescriptor] {
            switch self {
            #if os(iOS)
                case .iphoneAudio:
                    return [.appleSpeech]
            #endif
            default:
                return RecognitionModelStore.availableModels
            }
        }
    }
#endif
