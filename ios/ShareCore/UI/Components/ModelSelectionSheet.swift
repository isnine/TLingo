//
//  ModelSelectionSheet.swift
//  ShareCore
//

import SwiftUI

public struct ModelSelectionSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private enum Source {
        case enabledModels([ModelConfig])
        case single(Binding<ModelConfig>, [ModelConfig])
    }

    private let source: Source
    private let onRequiresPro: (() -> Void)?

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    public init(cloudModels: [ModelConfig], onRequiresPro: (() -> Void)? = nil) {
        source = .enabledModels(cloudModels)
        self.onRequiresPro = onRequiresPro
    }

    public init(
        selectedModel: Binding<ModelConfig>,
        availableModels: [ModelConfig],
        onRequiresPro: (() -> Void)? = nil
    ) {
        source = .single(selectedModel, availableModels)
        self.onRequiresPro = onRequiresPro
    }

    private var mode: ModelSelectionList.Mode {
        switch source {
        case let .enabledModels(cloudModels):
            .enabledModels(initialCloudModels: cloudModels)
        case let .single(selection, availableModels):
            .single(selection: selection, availableModels: availableModels) { dismiss() }
        }
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                ModelSelectionList(mode: mode, onRequiresPro: onRequiresPro)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("Models")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
