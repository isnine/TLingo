import CoreGraphics

public enum InspectorColumnWidth {
    public static let min: CGFloat = 280
    public static let ideal: CGFloat = 320
    public static let max: CGFloat = 900

    public static func clamped(_ width: CGFloat) -> CGFloat {
        Swift.min(Swift.max(width, min), max)
    }
}
