//
//  DataConsentView.swift
//  ShareCore
//
//  Created by Codex on 2026/02/13.
//

import SwiftUI

/// A compact consent dialog shown before the first translation request.
public struct DataConsentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private let onAccept: () -> Void
    private let onDecline: () -> Void

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private static let privacyPolicyURL = URL(
        string: "https://tlingo.zanderwang.com/privacy/"
    )!

    public init(onAccept: @escaping () -> Void, onDecline: @escaping () -> Void = {}) {
        self.onAccept = onAccept
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(spacing: 20) {
            // Icon
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 36))
                .foregroundColor(colors.accent)
                .padding(.top, 24)

            // Title
            Text("Data Sharing Notice")
                .font(.title3.bold())
                .foregroundColor(colors.textPrimary)

            // Description
            VStack(alignment: .leading, spacing: 10) {
                Text("Cloud models send text and images to their provider, sometimes through TLingo's servers:")
                    .font(.subheadline)
                    .foregroundColor(colors.textSecondary)

                Text(verbatim: "Microsoft Azure · Google · DeepSeek · OpenRouter · AICODE007 · Apple Private Cloud Compute")
                    .font(.subheadline.bold())
                    .foregroundColor(colors.textSecondary)

                Text("Cloud connections are encrypted. Provider privacy policies apply. On-device translation stays on your Mac.")
                    .font(.subheadline)
                    .foregroundColor(colors.textSecondary)
            }
            .padding(.horizontal, 24)
            .multilineTextAlignment(.leading)

            // Privacy link
            Link(destination: Self.privacyPolicyURL) {
                HStack(spacing: 4) {
                    Text("Privacy Policy")
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10))
                }
                .font(.subheadline)
            }

            Spacer()

            // Buttons
            VStack(spacing: 10) {
                Button {
                    onAccept()
                    dismiss()
                } label: {
                    Text("Agree & Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(colors.accent)

                Button {
                    onDecline()
                    dismiss()
                } label: {
                    Text("Decline")
                        .font(.subheadline)
                        .foregroundColor(colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(colors.background)
        .interactiveDismissDisabled()
    }
}
