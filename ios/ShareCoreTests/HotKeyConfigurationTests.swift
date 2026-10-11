#if os(macOS)
    import Carbon
    import Foundation
    @testable import ShareCore
    import Testing

    @Suite("Hotkey configuration persistence")
    struct HotKeyConfigurationTests {
        @Test("Restores modifier+A shortcuts", arguments: [
            UInt32(optionKey),
            UInt32(controlKey | optionKey),
            UInt32(controlKey | cmdKey),
        ])
        func restoresModifierA(modifiers: UInt32) throws {
            let suite = "HotKeyConfigurationTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let expected = HotKeyConfiguration(keyCode: UInt32(kVK_ANSI_A), modifiers: modifiers)
            defaults.set(expected.keyCode, forKey: "keyCode")
            defaults.set(expected.modifiers, forKey: "modifiers")

            let restored = HotKeyConfiguration.load(
                from: defaults, keyCodeKey: "keyCode", modifiersKey: "modifiers"
            )

            #expect(restored == expected)
            #expect(restored.isEmpty == false)
        }

        @Test("Preserves other shortcuts and cleared settings", arguments: [
            (UInt32(kVK_ANSI_B), UInt32(cmdKey)),
            (UInt32(kVK_F1), UInt32(0)),
            (UInt32(0), UInt32(0)),
        ])
        func preservesExistingConfigurations(keyCode: UInt32, modifiers: UInt32) throws {
            let suite = "HotKeyConfigurationTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(keyCode, forKey: "keyCode")
            defaults.set(modifiers, forKey: "modifiers")

            let restored = HotKeyConfiguration.load(
                from: defaults, keyCodeKey: "keyCode", modifiersKey: "modifiers"
            )

            #expect(restored == HotKeyConfiguration(keyCode: keyCode, modifiers: modifiers))
            #expect(restored.isEmpty == (keyCode == 0 && modifiers == 0))
        }

        @Test("Missing configuration fields remain empty", arguments: ["none", "keyCode", "modifiers"])
        func missingFieldsRemainEmpty(savedKey: String) throws {
            let suite = "HotKeyConfigurationTests-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if savedKey != "none" {
                defaults.set(UInt32(1), forKey: savedKey)
            }

            let restored = HotKeyConfiguration.load(
                from: defaults, keyCodeKey: "keyCode", modifiersKey: "modifiers"
            )

            #expect(restored == .empty)
        }
    }
#endif
