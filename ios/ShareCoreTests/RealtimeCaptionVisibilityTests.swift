#if os(macOS)
    import Testing

    @testable import ShareCore

    @Suite("Realtime caption visibility")
    struct RealtimeCaptionVisibilityTests {
        @Test("Context menu toggle flips caption visibility")
        func contextMenuToggleFlipsVisibility() {
            #expect(RealtimeCaptionVisibility.toggledValue(isVisible: true) == false)
            #expect(RealtimeCaptionVisibility.toggledValue(isVisible: false) == true)
        }

        @Test("Close control always hides caption visibility")
        func closeControlAlwaysHidesCaptionVisibility() {
            #expect(RealtimeCaptionVisibility.closedValue(isVisible: true) == false)
            #expect(RealtimeCaptionVisibility.closedValue(isVisible: false) == false)
        }
    }
#endif
