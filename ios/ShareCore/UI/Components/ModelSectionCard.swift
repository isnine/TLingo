//
//  ModelSectionCard.swift
//  ShareCore
//

import SwiftUI

public struct ModelSectionCard<Row: View, HeaderAccessory: View>: View {
    @Environment(\.colorScheme) private var colorScheme

    private let title: LocalizedStringKey
    private let icon: String
    private let tint: Color?
    private let models: [ModelConfig]
    private let collapsedModels: [ModelConfig]
    private let isExpanded: Binding<Bool>?
    private let dividerLeadingPadding: CGFloat
    private let cornerRadius: CGFloat
    private let row: (ModelConfig) -> Row
    private let headerAccessory: () -> HeaderAccessory

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    public init(
        title: LocalizedStringKey,
        icon: String,
        tint: Color? = nil,
        models: [ModelConfig],
        collapsedModels: [ModelConfig] = [],
        isExpanded: Binding<Bool>? = nil,
        dividerLeadingPadding: CGFloat = 54,
        cornerRadius: CGFloat = 14,
        @ViewBuilder row: @escaping (ModelConfig) -> Row,
        @ViewBuilder headerAccessory: @escaping () -> HeaderAccessory
    ) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.models = models
        self.collapsedModels = collapsedModels
        self.isExpanded = isExpanded
        self.dividerLeadingPadding = dividerLeadingPadding
        self.cornerRadius = cornerRadius
        self.row = row
        self.headerAccessory = headerAccessory
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            rows
                .background(cardBackground)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(tint ?? colors.textSecondary)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(tint ?? colors.textSecondary)
                .textCase(.uppercase)
            headerAccessory()
        }
        .padding(.leading, 4)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                row(model)
                if index < models.count - 1 || !collapsedModels.isEmpty {
                    divider
                }
            }

            if !collapsedModels.isEmpty, let isExpanded {
                collapsedModelsToggle(count: collapsedModels.count, isExpanded: isExpanded)

                if isExpanded.wrappedValue {
                    ForEach(collapsedModels, id: \.id) { model in
                        divider
                        row(model)
                    }
                }
            }
        }
    }

    private var divider: some View {
        Divider()
            .padding(.leading, dividerLeadingPadding)
    }

    private func collapsedModelsToggle(count: Int, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(colors.textSecondary.opacity(0.55))
                Text("\(count) more models")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(colors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(colors.divider, lineWidth: 1)
            )
    }
}

public extension ModelSectionCard where HeaderAccessory == EmptyView {
    init(
        title: LocalizedStringKey,
        icon: String,
        tint: Color? = nil,
        models: [ModelConfig],
        collapsedModels: [ModelConfig] = [],
        isExpanded: Binding<Bool>? = nil,
        dividerLeadingPadding: CGFloat = 54,
        cornerRadius: CGFloat = 14,
        @ViewBuilder row: @escaping (ModelConfig) -> Row
    ) {
        self.init(
            title: title,
            icon: icon,
            tint: tint,
            models: models,
            collapsedModels: collapsedModels,
            isExpanded: isExpanded,
            dividerLeadingPadding: dividerLeadingPadding,
            cornerRadius: cornerRadius,
            row: row,
            headerAccessory: { EmptyView() }
        )
    }
}
