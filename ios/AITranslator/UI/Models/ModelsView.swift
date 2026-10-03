//
//  ModelsView.swift
//  TLingo
//
//  Created by Codex on 2025/01/28.
//

import ShareCore
import SwiftUI

struct ModelsView: View {
    @Environment(\.colorScheme) private var colorScheme
    private let embedsInNavigationStack: Bool

    @State private var showPaywall = false

    init(embedsInNavigationStack: Bool = true) {
        self.embedsInNavigationStack = embedsInNavigationStack
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    var body: some View {
        navigationContainer
            .tint(colors.accent)
            .sheet(isPresented: $showPaywall) {
                PaywallView(context: .featureLocked)
            }
    }

    @ViewBuilder
    private var navigationContainer: some View {
        if embedsInNavigationStack {
            NavigationStack {
                content
                #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
                #endif
            }
        } else {
            content
            #if os(iOS)
            .toolbar(.visible, for: .navigationBar)
            #endif
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headerSection
                ModelSelectionList(mode: .enabledModels(initialCloudModels: [])) {
                    showPaywall = true
                }
                infoFooter
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 28)
        }
        .background(colors.background.ignoresSafeArea())
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Models")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(colors.textPrimary)
            Text("Select models to use for translation")
                .font(.system(size: 16))
                .foregroundColor(colors.textSecondary)
        }
    }

    private static let privacyPolicyURL = URL(
        string: "https://tlingo.zanderwang.com/privacy/"
    )!

    private var infoFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundColor(colors.success)
                Text("Powered by Built-in Cloud - No API key required")
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 14))
                        .foregroundColor(colors.textSecondary.opacity(0.6))
                    Text(
                        "Your translation text is sent to Microsoft Azure OpenAI Service for processing. "
                            + "Data is encrypted in transit and not stored after processing."
                    )
                    .font(.system(size: 12))
                    .foregroundColor(colors.textSecondary.opacity(0.8))
                }

                Link(destination: Self.privacyPolicyURL) {
                    HStack(spacing: 4) {
                        Text("Privacy Policy")
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10))
                    }
                    .font(.system(size: 12))
                }
                .padding(.leading, 22)
            }
        }
        .padding(.top, 8)
    }
}

#Preview {
    ModelsView()
        .preferredColorScheme(.dark)
}
