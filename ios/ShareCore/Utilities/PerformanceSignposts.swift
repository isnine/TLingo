import os

/// Instruments "Points of Interest" for user-visible latency. Keep interval names stable so traces stay comparable.
public enum PerformanceSignposts {
    public static let signposter = OSSignposter(
        subsystem: "com.zanderwang.AITranslator",
        category: .pointsOfInterest
    )
}
