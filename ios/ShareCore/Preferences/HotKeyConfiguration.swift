#if os(macOS)
    import Foundation

    public struct HotKeyConfiguration: Equatable, Codable {
        public var keyCode: UInt32
        public var modifiers: UInt32

        public static let empty = HotKeyConfiguration(keyCode: 0, modifiers: 0)

        public var isEmpty: Bool {
            keyCode == 0 && modifiers == 0
        }

        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        public static func load(
            from defaults: UserDefaults,
            keyCodeKey: String,
            modifiersKey: String
        ) -> HotKeyConfiguration {
            let keyCode = defaults.object(forKey: keyCodeKey) as? UInt32
            let modifiers = defaults.object(forKey: modifiersKey) as? UInt32
            if let keyCode, let modifiers {
                return HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers)
            }
            return .empty
        }
    }
#endif
