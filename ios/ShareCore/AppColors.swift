//
//  AppColors.swift
//  ShareCore
//
//  Created by Zander Wang on 2025/10/19.
//

import SwiftUI

// MARK: - Accent Theme

public enum AccentTheme: String, CaseIterable, Identifiable, Sendable {
    case orange
    case blue
    case purple
    case pink
    case green
    case red
    case teal
    case indigo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .orange: return String(localized: "Sunset")
        case .blue: return String(localized: "Ocean")
        case .purple: return String(localized: "Lavender")
        case .pink: return String(localized: "Rose")
        case .green: return String(localized: "Forest")
        case .red: return String(localized: "Ruby")
        case .teal: return String(localized: "Teal")
        case .indigo: return String(localized: "Indigo")
        }
    }

    public var color: Color {
        switch self {
        case .orange: return Color(red: 232 / 255, green: 98 / 255, blue: 40 / 255)
        case .blue: return Color(red: 82 / 255, green: 121 / 255, blue: 248 / 255)
        case .purple: return Color(red: 149 / 255, green: 97 / 255, blue: 226 / 255)
        case .pink: return Color(red: 226 / 255, green: 79 / 255, blue: 120 / 255)
        case .green: return Color(red: 52 / 255, green: 168 / 255, blue: 83 / 255)
        case .red: return Color(red: 211 / 255, green: 61 / 255, blue: 61 / 255)
        case .teal: return Color(red: 38 / 255, green: 166 / 255, blue: 154 / 255)
        case .indigo: return Color(red: 83 / 255, green: 82 / 255, blue: 196 / 255)
        }
    }

    /// Darker variant used for filled controls and for accent text in light mode;
    /// every value keeps white text at or above 4.5:1.
    public var strongColor: Color {
        switch self {
        case .orange: return Color(red: 202 / 255, green: 76 / 255, blue: 22 / 255)
        case .blue: return Color(red: 60 / 255, green: 104 / 255, blue: 247 / 255)
        case .purple: return Color(red: 142 / 255, green: 86 / 255, blue: 224 / 255)
        case .pink: return Color(red: 220 / 255, green: 44 / 255, blue: 93 / 255)
        case .green: return Color(red: 41 / 255, green: 133 / 255, blue: 66 / 255)
        case .red: return Color(red: 211 / 255, green: 61 / 255, blue: 61 / 255)
        case .teal: return Color(red: 29 / 255, green: 129 / 255, blue: 119 / 255)
        case .indigo: return Color(red: 83 / 255, green: 82 / 255, blue: 196 / 255)
        }
    }

    public static let `default`: AccentTheme = .blue
}

public enum AppColors {
    private static let background = AdaptiveColor(
        light: Color(red: 246 / 255, green: 246 / 255, blue: 250 / 255),
        dark: Color(red: 17 / 255, green: 17 / 255, blue: 24 / 255)
    )
    private static let cardBackground = AdaptiveColor(
        light: Color.white,
        dark: Color(red: 24 / 255, green: 24 / 255, blue: 31 / 255)
    )
    private static let inputBackground = AdaptiveColor(
        light: Color.white,
        dark: Color(red: 38 / 255, green: 38 / 255, blue: 44 / 255)
    )
    private static let textPrimary = AdaptiveColor(
        light: Color(red: 28 / 255, green: 28 / 255, blue: 34 / 255),
        dark: Color.white
    )
    private static let textSecondary = AdaptiveColor(
        light: Color.black.opacity(0.6),
        dark: Color.white.opacity(0.65)
    )
    private static let chipSecondaryBackground = AdaptiveColor(
        light: Color.black.opacity(0.05),
        dark: Color.white.opacity(0.25)
    )
    private static let chipSecondaryText = AdaptiveColor(
        light: Color.black.opacity(0.7),
        dark: Color.white
    )
    private static let divider = AdaptiveColor(
        light: Color.black.opacity(0.06),
        dark: Color.white.opacity(0.08)
    )
    private static let skeleton = AdaptiveColor(
        light: Color.black.opacity(0.08),
        dark: Color.white.opacity(0.12)
    )
    private static let success = AdaptiveColor(
        light: Color(red: 42 / 255, green: 160 / 255, blue: 90 / 255),
        dark: Color(red: 64 / 255, green: 193 / 255, blue: 129 / 255)
    )
    private static let error = AdaptiveColor(
        light: Color(red: 207 / 255, green: 74 / 255, blue: 74 / 255),
        dark: Color(red: 238 / 255, green: 110 / 255, blue: 115 / 255)
    )

    public static func palette(for colorScheme: ColorScheme) -> Palette {
        Palette(colorScheme: colorScheme, accentTheme: AppPreferences.shared.accentTheme)
    }

    public struct Palette {
        private let colorScheme: ColorScheme
        private let accentTheme: AccentTheme

        public init(colorScheme: ColorScheme, accentTheme: AccentTheme = .default) {
            self.colorScheme = colorScheme
            self.accentTheme = accentTheme
        }

        public var background: Color { AppColors.background.resolve(colorScheme) }
        public var cardBackground: Color { AppColors.cardBackground.resolve(colorScheme) }
        public var inputBackground: Color { AppColors.inputBackground.resolve(colorScheme) }
        /// Accent for text, icons and tints. Light mode uses the stronger variant so
        /// links and icons stay legible on white.
        public var accent: Color { colorScheme == .dark ? accentTheme.color : accentTheme.strongColor }
        /// Fill behind `onAccent` content: selected chips, send buttons, primary capsules.
        public var accentFill: Color { accentTheme.strongColor }
        public var onAccent: Color { Color.white }
        public var textPrimary: Color { AppColors.textPrimary.resolve(colorScheme) }
        public var textSecondary: Color { AppColors.textSecondary.resolve(colorScheme) }
        public var chipPrimaryBackground: Color { accentFill }
        public var chipSecondaryBackground: Color { AppColors.chipSecondaryBackground.resolve(colorScheme) }
        public var chipPrimaryText: Color { onAccent }
        public var chipSecondaryText: Color { AppColors.chipSecondaryText.resolve(colorScheme) }
        public var divider: Color { AppColors.divider.resolve(colorScheme) }
        public var skeleton: Color { AppColors.skeleton.resolve(colorScheme) }
        public var success: Color { AppColors.success.resolve(colorScheme) }
        public var error: Color { AppColors.error.resolve(colorScheme) }
    }

    private struct AdaptiveColor {
        private let light: Color
        private let dark: Color

        init(light: Color, dark: Color) {
            self.light = light
            self.dark = dark
        }

        func resolve(_ colorScheme: ColorScheme) -> Color {
            switch colorScheme {
            case .light:
                return light
            case .dark:
                return dark
            @unknown default:
                return dark
            }
        }
    }
}

public typealias AppColorPalette = AppColors.Palette

// MARK: - Environment Key

private struct AppColorsKey: EnvironmentKey {
    static let defaultValue = AppColors.Palette(colorScheme: .light)
}

public extension EnvironmentValues {
    var appColors: AppColorPalette {
        get { self[AppColorsKey.self] }
        set { self[AppColorsKey.self] = newValue }
    }
}

public extension View {
    func injectAppColors(for colorScheme: ColorScheme) -> some View {
        environment(\.appColors, AppColors.palette(for: colorScheme))
    }
}
