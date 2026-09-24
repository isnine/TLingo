#if os(macOS)
    import Foundation

    public enum RealtimeCaptionWindowMode: String, CaseIterable, Hashable, Identifiable {
        case floating
        case notch

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .floating:
                return String(localized: "Floating")
            case .notch:
                return String(localized: "Notch")
            }
        }

        public var settingsDescription: String {
            switch self {
            case .floating:
                return String(localized: "Resizable floating captions near the bottom of the screen")
            case .notch:
                return String(localized: "Compact captions blended into the MacBook notch area")
            }
        }
    }
#endif
