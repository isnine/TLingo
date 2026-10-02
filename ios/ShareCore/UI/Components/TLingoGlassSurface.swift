import SwiftUI

/// Named glass treatments so every floating surface shares one tint recipe.
public enum TLingoGlassStyle: Sendable {
    /// Bars and containers that hold other controls (composer, language bar).
    case chrome
    /// Neutral tappable controls (chips, icon buttons).
    case control
    /// Floating panels and prompts that carry their own content.
    case panel
    /// Primary action filled with the accent (send, start).
    case prominent
    /// Destructive or stop actions.
    case destructive

    struct Resolved {
        let tint: Color
        let fallbackTint: Color
        let fallbackStroke: Color
    }

    func resolve(_ colors: AppColorPalette, _ colorScheme: ColorScheme) -> Resolved {
        let isDark = colorScheme == .dark
        switch self {
        case .chrome:
            return Resolved(
                tint: colors.cardBackground.opacity(isDark ? 0.12 : 0.18),
                fallbackTint: colors.cardBackground.opacity(isDark ? 0.16 : 0.72),
                fallbackStroke: colors.divider
            )
        case .control:
            return Resolved(
                tint: colors.cardBackground.opacity(isDark ? 0.10 : 0.14),
                fallbackTint: colors.cardBackground.opacity(isDark ? 0.16 : 0.72),
                fallbackStroke: colors.divider
            )
        case .panel:
            return Resolved(
                tint: colors.cardBackground.opacity(isDark ? 0.16 : 0.22),
                fallbackTint: colors.cardBackground.opacity(isDark ? 0.72 : 0.88),
                fallbackStroke: colors.divider
            )
        case .prominent:
            return Resolved(
                tint: colors.accentFill.opacity(0.82),
                fallbackTint: colors.accentFill,
                fallbackStroke: .clear
            )
        case .destructive:
            return Resolved(
                tint: colors.error.opacity(0.82),
                fallbackTint: colors.error,
                fallbackStroke: .clear
            )
        }
    }
}

public extension View {
    func tlingoGlassSurface(
        _ style: TLingoGlassStyle,
        cornerRadius: CGFloat,
        interactive: Bool = false
    ) -> some View {
        modifier(TLingoStyledGlass(style: style, shape: .rect(cornerRadius), interactive: interactive))
    }

    func tlingoGlassCapsule(_ style: TLingoGlassStyle, interactive: Bool = false) -> some View {
        modifier(TLingoStyledGlass(style: style, shape: .capsule, interactive: interactive))
    }

    func tlingoGlassCircle(_ style: TLingoGlassStyle, interactive: Bool = false) -> some View {
        modifier(TLingoStyledGlass(style: style, shape: .circle, interactive: interactive))
    }
}

private struct TLingoStyledGlass: ViewModifier {
    enum GlassShape {
        case rect(CGFloat)
        case capsule
        case circle
    }

    let style: TLingoGlassStyle
    let shape: GlassShape
    let interactive: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let resolved = style.resolve(AppColors.palette(for: colorScheme), colorScheme)
        switch shape {
        case let .rect(cornerRadius):
            content.tlingoGlassSurface(
                cornerRadius: cornerRadius,
                tint: resolved.tint,
                interactive: interactive,
                fallbackTint: resolved.fallbackTint,
                fallbackStroke: resolved.fallbackStroke
            )
        case .capsule:
            content.tlingoGlassCapsule(
                tint: resolved.tint,
                interactive: interactive,
                fallbackTint: resolved.fallbackTint,
                fallbackStroke: resolved.fallbackStroke
            )
        case .circle:
            content.tlingoGlassCircle(
                tint: resolved.tint,
                interactive: interactive,
                fallbackTint: resolved.fallbackTint,
                fallbackStroke: resolved.fallbackStroke
            )
        }
    }
}

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
        modifier(TLingoFallbackSurface(shape: shape, fallbackTint: fallbackTint, fallbackStroke: fallbackStroke))
    }
}

/// Pre-26 material fallback. With Reduce Transparency on, the material is
/// replaced by an opaque card background so text keeps a stable contrast.
private struct TLingoFallbackSurface<S: Shape>: ViewModifier {
    let shape: S
    let fallbackTint: Color
    let fallbackStroke: Color

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(fallbackTint, in: shape)
                .background(AppColors.palette(for: colorScheme).cardBackground, in: shape)
                .overlay(shape.stroke(fallbackStroke, lineWidth: 1))
        } else {
            content
                .background(.ultraThinMaterial, in: shape)
                .background(fallbackTint, in: shape)
                .overlay(shape.stroke(fallbackStroke, lineWidth: 1))
        }
    }
}
