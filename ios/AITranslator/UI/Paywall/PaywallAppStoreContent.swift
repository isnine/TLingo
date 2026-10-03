//
//  PaywallAppStoreContent.swift
//  TLingo
//
//  App Store target paywall body: StoreKit 2 product list, subscribe
//  button, "current plan" badge, and the legal footer (Apple-mandated
//  Restore + Terms + Privacy links and the auto-renew disclosure).
//
//  Inert in Direct builds — `PaywallView` only instantiates this when
//  `BuildEnvironment.isDirectDistribution == false`.
//

import ShareCore
import StoreKit
import SwiftUI

struct PaywallAppStoreContent: View {
    let colors: AppColorPalette

    @ObservedObject private var storeManager = StoreManager.shared
    @ObservedObject private var entitlement = Entitlement.shared
    @State private var selectedProduct: Product?
    @State private var showEmailRestore = false
    @State private var trialDurations: [String: String] = [:]

    private var currentTierPriority: Int {
        guard let productID = storeManager.activePremiumProductID else { return -1 }
        return PremiumProduct.tierPriority(for: productID)
    }

    private var hasUpgradeOptions: Bool {
        if entitlement.state.suppressesAppStoreUpgrades { return false }
        return currentTierPriority < 2
    }

    private func isUpgrade(_ product: Product) -> Bool {
        PremiumProduct.tierPriority(for: product.id) > currentTierPriority
    }

    private var defaultProduct: Product? {
        if let annual = storeManager.annualProduct, isUpgrade(annual) { return annual }
        if let lifetime = storeManager.lifetimeProduct, isUpgrade(lifetime) { return lifetime }
        if let monthly = storeManager.monthlyProduct, isUpgrade(monthly) { return monthly }
        return nil
    }

    var body: some View {
        Group {
            if hasUpgradeOptions {
                productsSection
                subscribeButton
                legalFooter
            } else {
                currentPlanBadge
                legalFooter
            }
        }
        .sheet(isPresented: $showEmailRestore) {
            WebsitePurchaseRestoreView(colors: colors) {
                showEmailRestore = false
            }
        }
        .task(id: storeManager.products.map(\.id).joined(separator: "|")) {
            await loadTrialDurations()
        }
    }

    /// Reads each subscription's introductory free-trial period, keeping only the
    /// products this customer is actually eligible for. `introductoryOffer` is
    /// present regardless of eligibility, so `isEligibleForIntroOffer` is required
    /// to avoid promising a trial to someone who already used theirs.
    private func loadTrialDurations() async {
        var result: [String: String] = [:]
        for product in storeManager.subscriptionProducts {
            guard let subscription = product.subscription,
                  let offer = subscription.introductoryOffer,
                  offer.paymentMode == .freeTrial,
                  let duration = trialDurationText(offer.period)
            else { continue }
            if await subscription.isEligibleForIntroOffer {
                result[product.id] = duration
            }
        }
        trialDurations = result
    }

    private func trialDurationText(_ period: Product.SubscriptionPeriod) -> String? {
        var components = DateComponents()
        switch period.unit {
        case .day: components.day = period.value
        case .week: components.weekOfMonth = period.value
        case .month: components.month = period.value
        case .year: components.year = period.value
        @unknown default: return nil
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .weekOfMonth, .month, .year]
        formatter.maximumUnitCount = 1
        return formatter.string(from: components)
    }

    // MARK: - Products

    private var productsSection: some View {
        VStack(spacing: 0) {
            let annual = storeManager.annualProduct.flatMap { isUpgrade($0) ? $0 : nil }
            let lifetime = storeManager.lifetimeProduct.flatMap { isUpgrade($0) ? $0 : nil }
            let monthly = storeManager.monthlyProduct.flatMap { isUpgrade($0) ? $0 : nil }

            if let annual {
                productRow(
                    product: annual,
                    title: "Annual",
                    subtitle: annualSubtitle(annual: annual, monthly: monthly),
                    priceLabel: annual.displayPrice,
                    periodLabel: "/ year",
                    badge: "BEST VALUE"
                )
            }

            if lifetime != nil, annual != nil { sectionDivider }

            if let lifetime {
                productRow(
                    product: lifetime,
                    title: "Lifetime",
                    subtitle: String(localized: "One-time purchase, forever yours"),
                    priceLabel: lifetime.displayPrice,
                    periodLabel: nil,
                    badge: "BEST VALUE"
                )
            }

            if lifetime != nil || annual != nil, monthly != nil { sectionDivider }

            if let monthly {
                productRow(
                    product: monthly,
                    title: "Monthly",
                    subtitle: String(localized: "Billed monthly · cancel anytime"),
                    priceLabel: monthly.displayPrice,
                    periodLabel: "/ month",
                    badge: nil
                )
            }
        }
        .background(PaywallCard(colors: colors))
        .padding(.horizontal, 20)
        .onAppear {
            selectedProduct = defaultProduct
        }
        .onChange(of: storeManager.products.map(\.id).joined(separator: "|")) { _, _ in
            if selectedProduct == nil {
                selectedProduct = defaultProduct
            }
        }
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(colors.divider)
            .frame(height: 0.5)
            .padding(.leading, 56)
    }

    private func annualSubtitle(annual: Product, monthly: Product?) -> String {
        let perMonth = (annual.price / 12).formatted(annual.priceFormatStyle)
        guard let monthly else {
            return String(localized: "\(perMonth)/mo, billed annually")
        }

        let annualizedMonthly = monthly.price * 12
        guard annualizedMonthly > annual.price else {
            return String(localized: "\(perMonth)/mo, billed annually")
        }

        let savings = NSDecimalNumber(decimal: annualizedMonthly - annual.price)
            .dividing(by: NSDecimalNumber(decimal: annualizedMonthly))
            .multiplying(by: 100)
            .rounding(accordingToBehavior: NSDecimalNumberHandler(
                roundingMode: .down,
                scale: 0,
                raiseOnExactness: false,
                raiseOnOverflow: false,
                raiseOnUnderflow: false,
                raiseOnDivideByZero: false
            ))
            .intValue
        return String(localized: "\(perMonth)/mo, billed annually · save \(savings)%")
    }

    private func subscribeButtonTitle(for product: Product?) -> String {
        guard let product else { return String(localized: "Continue") }
        if let trial = trialDurations[product.id] {
            return String(localized: "Free Trial for \(trial)")
        }
        switch product.id {
        case SubscriptionProduct.annual.rawValue:
            return String(localized: "Continue Annual")
        case SubscriptionProduct.monthly.rawValue:
            return String(localized: "Continue Monthly")
        case LifetimeProduct.lifetime.rawValue:
            return String(localized: "Unlock Lifetime")
        default:
            return String(localized: "Continue")
        }
    }

    private func productRow(
        product: Product,
        title: LocalizedStringKey,
        subtitle: String,
        priceLabel: String,
        periodLabel: LocalizedStringKey?,
        badge: LocalizedStringKey?
    ) -> some View {
        let isSelected = selectedProduct?.id == product.id
        let trialText = trialDurations[product.id]

        return Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedProduct = product
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .stroke(isSelected ? colors.accent : colors.divider, lineWidth: isSelected ? 6 : 1.5)
                        .frame(width: 22, height: 22)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(colors.textPrimary)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule().fill(
                                        LinearGradient(
                                            colors: [Color.orange, Color.yellow],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                )
                        }
                    }

                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundColor(colors.textSecondary)

                    if let trialText {
                        Text("Includes \(trialText) free trial")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(colors.accent)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 0) {
                    Text(priceLabel)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundColor(colors.textPrimary)
                    if let periodLabel {
                        Text(periodLabel)
                            .font(.system(size: 11))
                            .foregroundColor(colors.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .tlingoGlassSurface(
                cornerRadius: 14,
                tint: isSelected ? colors.accent.opacity(0.20) : colors.cardBackground.opacity(0.10),
                interactive: true,
                fallbackTint: isSelected ? colors.accent.opacity(0.10) : Color.clear,
                fallbackStroke: isSelected ? colors.accent.opacity(0.28) : Color.clear
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Subscribe button

    private var subscribeButton: some View {
        let hasSelection = selectedProduct != nil

        return Button {
            guard let product = selectedProduct else { return }
            Task { await storeManager.purchase(product) }
        } label: {
            HStack(spacing: 8) {
                if storeManager.isPurchasing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                Text(storeManager.isPurchasing ? String(localized: "Processing") : subscribeButtonTitle(for: selectedProduct))
                    .font(.system(size: 17, weight: .semibold))

                if !storeManager.isPurchasing {
                    Image(systemName: "arrow.right")
                        .font(.system(size: 14, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .foregroundColor(hasSelection ? .white : colors.textSecondary.opacity(0.55))
            .tlingoGlassSurface(hasSelection ? .prominent : .control, cornerRadius: 15, interactive: hasSelection && !storeManager.isPurchasing)
        }
        .buttonStyle(.plain)
        .disabled(selectedProduct == nil || storeManager.isPurchasing)
        .padding(.horizontal, 20)
        .shadow(color: hasSelection ? colors.accent.opacity(0.20) : Color.clear, radius: 14, x: 0, y: 6)
    }

    // MARK: - Current plan badge (Lifetime)

    private var currentPlanBadge: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundColor(.green)

            Text("You have the best plan")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(colors.textPrimary)

            Text(entitlement.state.settingsSubtitle)
                .font(.system(size: 15))
                .foregroundColor(colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(PaywallCard(colors: colors))
        .padding(.horizontal, 20)
    }

    // MARK: - Legal

    private static let privacyPolicyURL = URL(
        string: "https://tlingo.zanderwang.com/privacy/"
    )!
    private static let termsOfUseURL = URL(
        string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"
    )!

    private var legalFooter: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("Already purchased in the App Store?")
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                Button {
                    Task { await storeManager.restorePurchases() }
                } label: {
                    Text("Restore")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.blue)
                        .underline()
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 4) {
                Text("Have an existing account?")
                    .font(.system(size: 13))
                    .foregroundColor(colors.textSecondary)
                Button {
                    showEmailRestore = true
                } label: {
                    Text("Restore with Email")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.blue)
                        .underline()
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 16) {
                Link("Terms of Use", destination: Self.termsOfUseURL)
                Link("Privacy Policy", destination: Self.privacyPolicyURL)
            }
            .font(.system(size: 11))
            .foregroundColor(colors.textSecondary.opacity(0.6))

            Text(disclosureText)
                .font(.system(size: 11))
                .foregroundColor(colors.textSecondary.opacity(0.6))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 28)
    }

    private var disclosureText: String {
        if selectedProduct?.id == LifetimeProduct.lifetime.rawValue {
            return String(localized: "Lifetime is a one-time purchase. Subscriptions restore from the App Store when available.")
        }
        let renewalText = String(localized: "Subscriptions renew automatically.")
        let cancellationText = String(
            localized: "Cancel at least 24 hours before the end of the current period to avoid renewal."
        )
        return "\(renewalText) \(cancellationText)"
    }
}
