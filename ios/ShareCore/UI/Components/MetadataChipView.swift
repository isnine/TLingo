//
//  MetadataChipView.swift
//  ShareCore
//

import SwiftUI

public struct MetadataChipView: View {
    public let text: String
    public let icon: String
    public let isPrimary: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    public init(_ text: String, icon: String, isPrimary: Bool = false) {
        self.text = text
        self.icon = icon
        self.isPrimary = isPrimary
    }

    public var body: some View {
        HStack(spacing: TLingoSpacing.xxs) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 12))
        }
        .foregroundColor(isPrimary ? colors.onAccent : colors.textSecondary)
        .padding(.horizontal, TLingoSpacing.xs)
        .padding(.vertical, TLingoSpacing.xxs)
        .background(isPrimary ? colors.accentFill : colors.chipSecondaryBackground)
        .clipShape(Capsule(style: .continuous))
    }
}
