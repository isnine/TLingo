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
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 12))
        }
        .foregroundColor(isPrimary ? .white : colors.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isPrimary ? colors.accent : colors.chipSecondaryBackground)
        .clipShape(Capsule())
    }
}
