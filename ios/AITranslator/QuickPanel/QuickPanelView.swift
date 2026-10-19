//
//  QuickPanelView.swift
//  TLingo
//
//  Input, single-select actions and multi-model results for the centered quick panel.
//

#if os(macOS)
    import AppKit
    import ShareCore
    import SwiftUI

    struct QuickPanelView: View {
        @Environment(\.colorScheme) private var colorScheme
        @StateObject private var viewModel = HomeViewModel()
        @ObservedObject private var preferences = AppPreferences.shared
        @ObservedObject private var entitlement = Entitlement.shared
        @State private var showModelSelection = false
        /// Input of the last run; while the input still matches it, the composer collapses to one row.
        @State private var submittedText: String?
        let onClose: () -> Void

        private static let cornerRadius: CGFloat = 24
        private static let resultsHeight: CGFloat = 420
        private static let maxActionShortcuts = 9

        private var colors: AppColorPalette {
            AppColors.palette(for: colorScheme)
        }

        private var isCompact: Bool {
            !viewModel.modelRuns.isEmpty && submittedText == viewModel.inputText
        }

        private var trimmedInput: String {
            viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var body: some View {
            VStack(spacing: 0) {
                inputRow
                if !isCompact {
                    actionRow
                }

                if !viewModel.modelRuns.isEmpty {
                    Rectangle()
                        .fill(colors.divider)
                        .frame(height: 1)
                    HomeView(
                        viewModel: viewModel,
                        showsOnlyResults: true,
                        onResultConversation: { _ in openInMainApp() }
                    )
                    .frame(height: Self.resultsHeight)
                }

                footer
            }
            .frame(width: QuickPanelController.width)
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(colors.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .stroke(colors.divider, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { height in
                QuickPanelController.shared.updateContentHeight(height)
            }
            .animation(.smooth(duration: 0.2), value: isCompact)
            .background(actionShortcuts)
            .onExitCommand(perform: onClose)
            .onAppear {
                NotificationCenter.default.post(
                    name: .appleTranslationViewModelRegister,
                    object: nil,
                    userInfo: ["viewModel": viewModel]
                )
            }
            .onReceive(NotificationCenter.default.publisher(for: .quickPanelDidShow)) { _ in
                preferences.refreshFromDefaults()
                viewModel.refreshConfiguration()
            }
            .sheet(isPresented: $showModelSelection) {
                ModelSelectionSheet(cloudModels: viewModel.models)
            }
            .sheet(isPresented: $viewModel.showDataConsentRequest) {
                DataConsentView {
                    preferences.setHasAcceptedDataSharing(true)
                    viewModel.performSelectedAction()
                }
                .interactiveDismissDisabled()
            }
        }

        // MARK: - Input

        private var inputRow: some View {
            // The editor keeps its place in this row in both layouts, so collapsing never rebuilds it or drops focus.
            HStack(alignment: isCompact ? .center : .top, spacing: 12) {
                // AppKit text view: it takes typing in a non-activating panel, unlike a SwiftUI TextField.
                SelectableTextEditor(
                    text: $viewModel.inputText,
                    textColor: colors.textPrimary,
                    fontSize: 20,
                    onUserEdit: { viewModel.markUserEditedInput() },
                    onSwapLanguages: { viewModel.swapInputLanguages() }
                )
                .frame(height: isCompact ? 34 : 64)
                .frame(minWidth: 180)
                .overlay(alignment: .topLeading) {
                    if viewModel.inputText.isEmpty {
                        Text("Type or paste text")
                            .font(.system(size: 20))
                            .foregroundStyle(colors.textSecondary)
                            .padding(.leading, 4)
                            .padding(.top, 4)
                            .allowsHitTesting(false)
                    }
                }

                if isCompact {
                    actionChips
                        .frame(maxWidth: 440)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, isCompact ? 14 : 20)
            .padding(.bottom, isCompact ? 14 : 12)
        }

        private var modelButton: some View {
            Button {
                showModelSelection = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "cpu")
                        .font(.system(size: 12, weight: .medium))
                    Text(modelTitle.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if modelTitle.extraCount > 0 {
                        Text(verbatim: "+\(modelTitle.extraCount)")
                            .font(.system(size: 13, weight: .medium))
                            .fixedSize()
                    }
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .opacity(0.65)
                }
                .foregroundStyle(colors.textSecondary)
                .frame(maxWidth: 200, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose models")
        }

        /// The name truncates on its own so the "+N" count stays visible.
        private var modelTitle: (name: String, extraCount: Int) {
            let selected = viewModel.selectedDisplayModels(
                enabledIDs: preferences.enabledModelIDs,
                isPro: entitlement.isPro
            )
            guard let first = selected.first else { return (String(localized: "Models"), 0) }
            return (first.displayName, selected.count - 1)
        }

        // MARK: - Actions

        private var actionRow: some View {
            HStack(spacing: 12) {
                actionChips
                    .frame(maxWidth: .infinity, alignment: .leading)
                modelButton
            }
            .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }

        private var actionChips: some View {
            ActionChipsView(
                actions: viewModel.actions,
                selectedActionID: viewModel.selectedAction?.id,
                spacing: 8,
                font: .system(size: 13, weight: .medium),
                textColor: { isSelected in
                    isSelected ? .white : colors.chipSecondaryText
                },
                background: { isSelected in
                    Capsule()
                        .fill(isSelected ? colors.chipPrimaryBackground : colors.chipSecondaryBackground)
                },
                horizontalPadding: 14,
                verticalPadding: 7,
                onSelect: select
            )
        }

        /// ⌘1–⌘9 pick an action, matching the order of the chips.
        private var actionShortcuts: some View {
            ZStack {
                ForEach(Array(viewModel.actions.prefix(Self.maxActionShortcuts).enumerated()), id: \.element.id) { index, action in
                    Button("") { select(action) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }

        private func select(_ action: ActionConfig) {
            if viewModel.selectAction(action) {
                run()
            }
        }

        private func run() {
            let text = trimmedInput
            guard !text.isEmpty else { return }
            viewModel.inputText = text
            submittedText = text
            viewModel.performSelectedAction()
        }

        // MARK: - Footer

        private var footer: some View {
            HStack(spacing: 12) {
                LanguageSwitcherView(
                    globeFont: .system(size: 10),
                    textFont: .system(size: 12, weight: .medium),
                    chevronFont: .system(size: 8),
                    foregroundColor: colors.textSecondary,
                    showsControlBackgrounds: false,
                    languageDependencies: viewModel.selectedAction?.languageDependencies ?? .none,
                    resolvedTarget: viewModel.resolvedTargetLanguage,
                    onOverrideTarget: { viewModel.overrideTargetLanguage($0) },
                    detectedSource: viewModel.detectedSourceLanguage,
                    onSourceChanged: { viewModel.clearDetectedSourceLanguage() }
                )

                Spacer(minLength: 0)

                HStack(spacing: 16) {
                    Button(action: run) {
                        shortcutHint("Run", keys: ["⌘", "↩"], isPrimary: true)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.return, modifiers: .command)
                    Button(action: openInMainApp) {
                        shortcutHint("Open in App", keys: ["⌘", "O"], isPrimary: false)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut("o", modifiers: .command)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }

        private func shortcutHint(_ title: LocalizedStringKey, keys: [String], isPrimary: Bool) -> some View {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: isPrimary ? .semibold : .medium))
                    .foregroundStyle(isPrimary ? colors.textPrimary : colors.textSecondary)
                ForEach(keys, id: \.self) { key in
                    Text(verbatim: key)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .frame(minWidth: 20, minHeight: 20)
                        .padding(.horizontal, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(colors.chipSecondaryBackground)
                        )
                }
            }
        }

        /// Hands the input, action and results to the main window's HomeView.
        private func openInMainApp() {
            let snapshot = viewModel.captureStateSnapshot()
            onClose()
            HomeInputRouter.shared.submit(.handoff(snapshot))
            AppDelegate.shared?.openMainWindow()
        }
    }
#endif
