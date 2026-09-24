import SwiftUI

public extension View {
    @ViewBuilder
    func tlingoGlassSurface(
        cornerRadius: CGFloat,
        tint: Color = .clear,
        interactive: Bool = false,
        fallbackTint: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(tlingoGlass(tint: tint, interactive: interactive), in: .rect(cornerRadius: cornerRadius))
        } else {
            tlingoFallbackSurface(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                fallbackTint: fallbackTint,
                fallbackStroke: fallbackStroke
            )
        }
    }

    @ViewBuilder
    func tlingoGlassCapsule(
        tint: Color = .clear,
        interactive: Bool = false,
        fallbackTint: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(tlingoGlass(tint: tint, interactive: interactive), in: .capsule)
        } else {
            tlingoFallbackSurface(
                shape: Capsule(style: .continuous),
                fallbackTint: fallbackTint,
                fallbackStroke: fallbackStroke
            )
        }
    }

    @ViewBuilder
    func tlingoGlassCircle(
        tint: Color = .clear,
        interactive: Bool = false,
        fallbackTint: Color = .clear,
        fallbackStroke: Color = .clear
    ) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            glassEffect(tlingoGlass(tint: tint, interactive: interactive), in: .circle)
        } else {
            tlingoFallbackSurface(
                shape: Circle(),
                fallbackTint: fallbackTint,
                fallbackStroke: fallbackStroke
            )
        }
    }
}

@available(iOS 26.0, macOS 26.0, *)
private func tlingoGlass(tint: Color, interactive: Bool) -> Glass {
    let tinted = Glass.regular.tint(tint)
    return interactive ? tinted.interactive() : tinted
}

private extension View {
    func tlingoFallbackSurface<S: Shape>(
        shape: S,
        fallbackTint: Color,
        fallbackStroke: Color
    ) -> some View {
        background(.ultraThinMaterial, in: shape)
            .background(fallbackTint, in: shape)
            .overlay(shape.stroke(fallbackStroke, lineWidth: 1))
    }
}
