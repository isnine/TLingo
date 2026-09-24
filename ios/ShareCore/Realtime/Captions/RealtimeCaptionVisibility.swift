#if os(macOS)
    public enum RealtimeCaptionVisibility {
        public static func menuTitle(isVisible: Bool) -> String {
            isVisible ? "Hide Live Captions" : "Show Live Captions"
        }

        public static func toggledValue(isVisible: Bool) -> Bool {
            !isVisible
        }

        public static func closedValue(isVisible _: Bool) -> Bool {
            false
        }
    }
#endif
