#if os(macOS)
    import SwiftUI

    struct RealtimeNotchCaptionShape: InsettableShape {
        var bottomCornerRadiusRatio: CGFloat = 0.18
        var sideWallDepthRatio: CGFloat = 0.82
        var insetAmount: CGFloat = 0

        func path(in rect: CGRect) -> Path {
            let notchRect = rect.insetBy(dx: insetAmount, dy: insetAmount)
            guard notchRect.width > 0, notchRect.height > 0 else { return Path() }

            let depthRatio = max(0.60, min(sideWallDepthRatio, 0.95))
            let lowerArcStartY = notchRect.minY + (notchRect.height * depthRatio)
            let maxBottomRadiusFromDepth = max(0, notchRect.maxY - lowerArcStartY)
            let maxBottomRadiusFromWidth = notchRect.width * 0.5
            let targetBottomRadius = notchRect.height * bottomCornerRadiusRatio
            let bottomRadius = max(0, min(targetBottomRadius, min(maxBottomRadiusFromDepth, maxBottomRadiusFromWidth)))

            var path = Path()
            path.move(to: CGPoint(x: notchRect.minX, y: notchRect.minY))
            path.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.minY))
            path.addLine(to: CGPoint(x: notchRect.maxX, y: notchRect.maxY - bottomRadius))
            if bottomRadius > 0 {
                path.addArc(
                    center: CGPoint(x: notchRect.maxX - bottomRadius, y: notchRect.maxY - bottomRadius),
                    radius: bottomRadius,
                    startAngle: .degrees(0),
                    endAngle: .degrees(90),
                    clockwise: false
                )
            }
            path.addLine(to: CGPoint(x: notchRect.minX + bottomRadius, y: notchRect.maxY))
            if bottomRadius > 0 {
                path.addArc(
                    center: CGPoint(x: notchRect.minX + bottomRadius, y: notchRect.maxY - bottomRadius),
                    radius: bottomRadius,
                    startAngle: .degrees(90),
                    endAngle: .degrees(180),
                    clockwise: false
                )
            }
            path.closeSubpath()
            return path
        }

        func inset(by amount: CGFloat) -> some InsettableShape {
            var shape = self
            shape.insetAmount += amount
            return shape
        }
    }
#endif
