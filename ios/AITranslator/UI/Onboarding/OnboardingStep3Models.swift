//
//  OnboardingStep3Models.swift
//  TLingo
//
//  Step 3 of first-launch onboarding: choose premium models to try.
//

#if os(macOS)
    import ShareCore
    import SwiftUI

    struct OnboardingStep3Models: View {
        @Binding var selectedModelIDs: Set<String>
        let models: [ModelConfig]
        let colors: AppColorPalette

        var body: some View {
            VStack(spacing: 16) {
                OnboardingStepHeader(
                    systemImage: "square.stack.3d.up.fill",
                    iconColor: colors.accent,
                    title: "Choose models to try",
                    subtitle: "Choose one or more models for more natural translations or clearer writing.",
                    colors: colors
                )

                if models.isEmpty {
                    ProgressView("Loading premium models…")
                        .font(.system(size: 12))
                        .foregroundColor(colors.textSecondary)
                        .frame(maxWidth: .infinity)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(models, id: \.id) { model in
                                modelRow(model)
                            }
                        }
                    }
                    .frame(maxHeight: 238)
                }

                if !models.isEmpty, selectedAIModelIDs.isEmpty {
                    Text("Select at least one AI model to continue.")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }

                Spacer(minLength: 0)
            }
        }

        private func modelRow(_ model: ModelConfig) -> some View {
            HStack(spacing: 14) {
                Image(systemName: iconName(for: model))
                    .font(.system(size: 20))
                    .foregroundColor(colors.accent)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.textPrimary)
                    Text(subtitle(for: model))
                        .font(.system(size: 12))
                        .foregroundColor(colors.textSecondary)
                }

                Spacer()

                Toggle("", isOn: binding(for: model.id))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(colors.cardBackground)
            )
        }

        private func binding(for id: String) -> Binding<Bool> {
            Binding(
                get: { selectedModelIDs.contains(id) },
                set: { isOn in
                    if isOn {
                        selectedModelIDs.insert(id)
                    } else {
                        selectedModelIDs.remove(id)
                    }
                }
            )
        }

        private var selectedAIModelIDs: Set<String> {
            selectedModelIDs.intersection(Set(models.filter {
                $0.isPremium || $0.id == ModelConfig.nanoModelID
            }.map(\.id)))
        }

        private func iconName(for model: ModelConfig) -> String {
            if model.id == ModelConfig.appleTranslateID || model.id == ModelConfig.foundationModelID {
                return "apple.logo"
            }
            if model.id == ModelConfig.googleTranslateID {
                return "globe"
            }
            if model.id == ModelConfig.privateCloudModelID {
                return "cloud.fill"
            }
            return "cpu"
        }

        private func subtitle(for model: ModelConfig) -> LocalizedStringKey {
            if model.id == ModelConfig.appleTranslateID {
                return "Translate privately on your Mac"
            }
            if model.id == ModelConfig.googleTranslateID {
                return "Translate almost any language quickly"
            }
            if model.id == ModelConfig.foundationModelID {
                return "Clearer writing on your device"
            }
            if model.id == ModelConfig.privateCloudModelID {
                return "More natural translations and clearer writing"
            }
            return "More natural translations and clearer writing"
        }
    }
#endif
