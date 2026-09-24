#if os(macOS)
    import Testing

    @testable import ShareCore

    @Suite("Realtime caption window mode")
    struct RealtimeCaptionWindowModeTests {
        @Test("Mode raw values are stable for preferences")
        func rawValuesAreStable() {
            #expect(RealtimeCaptionWindowMode.floating.rawValue == "floating")
            #expect(RealtimeCaptionWindowMode.notch.rawValue == "notch")
        }

        @Test("Mode titles are user visible")
        func titlesAreUserVisible() {
            #expect(RealtimeCaptionWindowMode.floating.title == "Floating")
            #expect(RealtimeCaptionWindowMode.notch.title == "Notch")
        }
    }
#endif
