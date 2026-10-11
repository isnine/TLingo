#if os(macOS)
    public enum RealtimeCaptionVisibility {
        public static func toggledValue(isVisible: Bool) -> Bool {
            !isVisible
        }

        public static func closedValue(isVisible _: Bool) -> Bool {
            false
        }
    }
#endif
