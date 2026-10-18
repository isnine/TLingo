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

    @State private var isReordering = false

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

    private var canReorder: Bool {
        if case .enabledModels = source {
            return true
        }
        return false
    }

    /// Reorder mode lists the same models the selection list shows.
    private var orderCloudModels: [ModelConfig] {
        switch source {
        case let .enabledModels(cloudModels):
            cloudModels.isEmpty ? (ModelsService.shared.getCachedModels() ?? []) : cloudModels
        case let .single(_, availableModels):
            availableModels
        }
    }

    private var title: LocalizedStringKey {
        isReordering ? "Reorder" : "Models"
    }

    private var reorderButton: some View {
        Button {
            isReordering = true
        } label: {
            Label("Reorder", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityIdentifier("models.reorder")
    }

    #if os(macOS)
        private var macHeader: some View {
            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    if isReordering {
                        ModelListOrderResetButton()
                    } else if canReorder {
                        reorderButton
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                Divider()
            }
            .background(.bar)
        }
    #endif

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                #if os(macOS)
                    macHeader
                #endif
                if isReordering {
                    ModelListOrderList(cloudModels: orderCloudModels)
                } else {
                    ScrollView {
                        ModelSelectionList(mode: mode, showsReorderButton: false, onRequiresPro: onRequiresPro)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 18)
                    }
                }
            }
            #if os(macOS)
            // The macOS sheet sizes to its content: a List has no height of its own and a
            // ScrollView grows to fit every row. One fixed height keeps both modes the same size.
            .frame(height: 720)
            #endif
            .background(colors.background.ignoresSafeArea())
            .navigationTitle(title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #else
                // macOS sheets drop primary-action toolbar items, so the title row is drawn here.
                .toolbar(removing: .title)
            #endif
                .toolbar {
                    #if os(iOS)
                        if isReordering {
                            ToolbarItem(placement: ModelListOrderResetButton.placement) {
                                ModelListOrderResetButton()
                            }
                        } else if canReorder {
                            ToolbarItem(placement: .primaryAction) {
                                reorderButton
                            }
                        }
                    #endif
                    ToolbarItem(placement: .confirmationAction) {
                        if isReordering {
                            Button("Done") { isReordering = false }
                        } else {
                            Button("Done") { dismiss() }
                        }
                    }
                }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #endif
    }
}
