#if os(macOS) || os(iOS)
    import Foundation

    public enum RealtimeRecognitionEngine: String, CaseIterable, Identifiable {
        case appleSpeech = "apple_speech"

        public static let `default`: RealtimeRecognitionEngine = .appleSpeech

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .appleSpeech:
                return String(localized: "Apple Speech")
            }
        }

        public var systemImage: String {
            switch self {
            case .appleSpeech:
                return "captions.bubble"
            }
        }

        public var requiresSpeechRecognitionPermission: Bool {
            self == .appleSpeech
        }
    }
#endif
