//
//  ModelPickerMenu.swift
//  ShareCore
//

import SwiftUI

public struct ModelPickerMenu: View {
    @ObservedObject private var entitlement = Entitlement.shared

    @Binding private var selectedModel: ModelConfig
    private let availableModels: [ModelConfig]
    private let maxLabelWidth: CGFloat
    private let onRequiresPro: (() -> Void)?

    public init(
        selectedModel: Binding<ModelConfig>,
        availableModels: [ModelConfig],
        maxLabelWidth: CGFloat = 150,
        onRequiresPro: (() -> Void)? = nil
    ) {
        _selectedModel = selectedModel
        self.availableModels = availableModels
        self.maxLabelWidth = maxLabelWidth
        self.onRequiresPro = onRequiresPro
    }

    public var body: some View {
        Menu {
            ForEach(availableModels) { model in
                Button {
                    select(model)
                } label: {
                    HStack {
                        Text(model.displayName)
                        Image(systemName: accessIcon(for: model))
                        if model.id == selectedModel.id {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            label
        }
        .buttonStyle(.plain)
    }

    private var label: some View {
        Label {
            Text(selectedModel.displayName)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: "cpu")
        }
        .frame(maxWidth: maxLabelWidth, alignment: .leading)
    }

    private func select(_ model: ModelConfig) {
        Task {
            let isPro = await entitlement.refreshAndGetIsPro()
            guard !model.isPremium || isPro else {
                onRequiresPro?()
                return
            }
            selectedModel = model
        }
    }

    private func accessIcon(for model: ModelConfig) -> String {
        if !model.isPremium {
            return "lock.open.fill"
        }
        return entitlement.isPro ? "crown.fill" : "lock.fill"
    }
}
