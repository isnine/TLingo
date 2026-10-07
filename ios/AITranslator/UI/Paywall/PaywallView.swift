//
//  PaywallView.swift
//  TLingo
//
//  Routes the paywall body by distribution channel:
//    • App Store target → PaywallAppStoreContent (StoreKit IAP)
//    • Direct target    → PaywallDirectContent (Web Stripe + OAuth)
//

import ShareCore
import StoreKit
import SwiftUI

enum PaywallPresentationContext: Equatable {
    case standard
    case firstRunOnboarding
    case settingsUpgrade
    case featureLocked

    var showsOnboardingPages: Bool {
        self == .firstRunOnboarding
    }

    var showsContinueFree: Bool {
        self == .firstRunOnboarding
    }
}

struct PaywallView: View {
    let context: PaywallPresentationContext
    let onContinueFree: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var entitlement = Entitlement.shared

    @State private var celebrate = false
    @State private var didCelebrate = false

    init(
        context: PaywallPresentationContext = .standard,
        onContinueFree: (() -> Void)? = nil
    ) {
        self.context = context
        self.onContinueFree = onContinueFree
    }

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var hasUpgradeOptions: Bool {
        if entitlement.state.suppressesAppStoreUpgrades { return false }
        return currentTierPriority < 2
    }

    private var currentTierPriority: Int {
        guard let productID = storeManager.activePremiumProductID else { return -1 }
        return PremiumProduct.tierPriority(for: productID)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if context.showsOnboardingPages, !entitlement.isPro {
                        PaywallOnboardingView(colors: colors)
                    } else {
                        PaywallHero(colors: colors, hasUpgradeOptions: hasUpgradeOptions, isPremium: entitlement.isPro)
                        PaywallFeatures(colors: colors)
                    }

                    if BuildEnvironment.isDirectDistribution {
                        PaywallDirectContent(colors: colors)
                    } else {
                        PaywallAppStoreContent(colors: colors)
                    }

                    #if os(iOS)
                        if context.showsContinueFree, !entitlement.isPro {
                            Button {
                                onContinueFree?()
                                dismiss()
                            } label: {
                                Text("Continue Free")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(colors.textSecondary)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 20)
                        }
                    #endif
                }
                .padding(.vertical, 28)
            }
            .background(colors.background.ignoresSafeArea())
            .navigationTitle("")
            #if os(iOS)
                .toolbar(.hidden, for: .navigationBar)
            #else
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        closeButton
                    }
                }
            #endif
                .overlay {
                    if celebrate {
                        CelebrationOverlay(colors: colors)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                    }
                }
        }
        #if os(iOS)
            .safeAreaInset(edge: .top) {
                HStack {
                    Spacer()
                    closeButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
            }
        #endif
        .tint(colors.accent)
        .onChange(of: storeManager.activePremiumProductID) { _, newID in
            if newID != nil {
                triggerCelebration()
            }
        }
        .onChange(of: entitlement.isPro) { wasPro, isPro in
            if !wasPro, isPro {
                triggerCelebration()
            }
        }
    }

    private var closeButton: some View {
        Button {
            onContinueFree?()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(colors.textSecondary.opacity(0.6))
                .frame(width: 32, height: 32)
                .tlingoGlassCircle(.control, interactive: true)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Close")
    }

    private func triggerCelebration() {
        guard !didCelebrate else { return }
        didCelebrate = true
        withAnimation(.easeOut(duration: 0.3)) {
            celebrate = true
        }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            dismiss()
        }
    }
}

// MARK: - Shared building blocks

/// Crown + headline + subhead. Both channels render this above the fold.
struct PaywallHero: View {
    let colors: AppColorPalette
    let hasUpgradeOptions: Bool
    let isPremium: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "crown.fill")
                .font(.system(size: 48))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.yellow, Color.orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Text(
                hasUpgradeOptions
                    ? (isPremium ? "Upgrade Your Plan" : "Upgrade to Premium")
                    : "Premium Active"
            )
            .font(.system(size: 28, weight: .bold))
            .foregroundColor(colors.textPrimary)

            Text(
                hasUpgradeOptions
                    ? (
                        isPremium
                            ? "Switch to a higher tier for even more value"
                            : "Unlock the most powerful translation models"
                    )
                    : "Thank you for your support!"
            )
            .font(.system(size: 16))
            .foregroundColor(colors.textSecondary)
            .multilineTextAlignment(.center)
        }
        .padding(.top, 8)
    }
}

/// "What you get" feature list. Identical content for both channels.
struct PaywallFeatures: View {
    let colors: AppColorPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            row(
                icon: "sparkles",
                title: "Premium Models",
                description: "GPT-5.6, DeepSeek-V4.1-Flash, DeepSeek-V4-Pro, Qwen 3.7 Flash, GLM 5.3 Flash, Gemini 3.8 Flash, Gemini 3.1 Pro Preview"
            )
            row(icon: "bolt.fill", title: "Higher Quality", description: "More accurate and nuanced translations")
            row(icon: "text.badge.checkmark", title: "Unlimited Models", description: "Select as many models as you need")
            row(
                icon: "arrow.triangle.2.circlepath",
                title: "Always Up-to-Date",
                description: "Access to the latest models as they launch"
            )
            row(
                icon: "macbook.and.iphone",
                title: "Works on iPhone & Mac",
                description: "One subscription, all your Apple devices"
            )
        }
        .padding(20)
        .background(PaywallCard(colors: colors))
    }

    private func row(icon: String, title: LocalizedStringKey, description: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(colors.accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(colors.textPrimary)
                Text(description)
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
            }
        }
    }
}

/// Common card surface (rounded fill + 1pt divider stroke). Use as a
/// `.background()` for any boxed paywall section.
struct PaywallCard: View {
    let colors: AppColorPalette

    var body: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(colors.cardBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(colors.divider, lineWidth: 1)
            )
    }
}

#Preview {
    PaywallView()
        .preferredColorScheme(.dark)
}

// MARK: - Celebration

/// Full-screen confetti burst + "Thank you" toast shown right after a
/// successful subscription / restore. Self-contained: pure SwiftUI, no
/// third-party deps. Auto-fades; caller dismisses the sheet on a timer.
struct CelebrationOverlay: View {
    let colors: AppColorPalette
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey
    let toastTopInset: CGFloat?

    private static let pieces: [ConfettiPiece] = (0 ..< 70).map { _ in ConfettiPiece.random() }

    @State private var animate = false

    init(
        colors: AppColorPalette,
        title: LocalizedStringKey = "Thank You for Subscribing!",
        subtitle: LocalizedStringKey = "Premium features are now unlocked.",
        toastTopInset: CGFloat? = nil
    ) {
        self.colors = colors
        self.title = title
        self.subtitle = subtitle
        self.toastTopInset = toastTopInset
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.001) // capture layout, no visual

            GeometryReader { geo in
                ZStack {
                    ForEach(Self.pieces) { piece in
                        Rectangle()
                            .fill(piece.color)
                            .frame(width: piece.size.width, height: piece.size.height)
                            .rotationEffect(.degrees(animate ? piece.endRotation : piece.startRotation))
                            .position(
                                x: geo.size.width * piece.startX,
                                y: animate ? geo.size.height + 40 : -40
                            )
                            .opacity(animate ? 0 : 1)
                            .animation(
                                .easeIn(duration: piece.duration).delay(piece.delay),
                                value: animate
                            )
                    }
                }
            }

            VStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.yellow, Color.orange],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(animate ? 1 : 0.4)
                    .opacity(animate ? 1 : 0)
                    .animation(.spring(response: 0.45, dampingFraction: 0.6), value: animate)

                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundColor(colors.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .tlingoGlassSurface(
                cornerRadius: 18,
                tint: colors.cardBackground.opacity(0.18),
                fallbackTint: colors.cardBackground.opacity(0.92),
                fallbackStroke: colors.divider
            )
            .shadow(color: .black.opacity(0.18), radius: 20, x: 0, y: 8)
            .opacity(animate ? 1 : 0)
            .scaleEffect(animate ? 1 : 0.85)
            .animation(.spring(response: 0.5, dampingFraction: 0.75), value: animate)
            .padding(.top, toastTopInset ?? 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: toastTopInset == nil ? .center : .top)
        }
        .ignoresSafeArea()
        .onAppear { animate = true }
    }
}

private struct ConfettiPiece: Identifiable {
    let id = UUID()
    let color: Color
    let size: CGSize
    let startX: CGFloat // 0...1 fraction of width
    let startRotation: Double
    let endRotation: Double
    let duration: Double
    let delay: Double

    static func random() -> ConfettiPiece {
        let palette: [Color] = [.pink, .orange, .yellow, .green, .blue, .purple, .red, .mint]
        let width = CGFloat.random(in: 6 ... 10)
        let height = CGFloat.random(in: 10 ... 16)
        return ConfettiPiece(
            color: palette.randomElement() ?? .yellow,
            size: CGSize(width: width, height: height),
            startX: CGFloat.random(in: 0 ... 1),
            startRotation: Double.random(in: 0 ... 360),
            endRotation: Double.random(in: 360 ... 1080),
            duration: Double.random(in: 1.2 ... 1.8),
            delay: Double.random(in: 0 ... 0.25)
        )
    }
}
