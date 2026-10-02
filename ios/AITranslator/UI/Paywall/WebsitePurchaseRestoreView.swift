//
//  WebsitePurchaseRestoreView.swift
//  TLingo
//

import ShareCore
import SwiftUI

struct WebsitePurchaseRestoreView: View {
    let colors: AppColorPalette
    let onDone: () -> Void

    @ObservedObject private var restore = WebsitePurchaseRestoreCoordinator.shared
    @State private var email = ""
    @State private var code = ""
    @State private var didSendCode = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Restore with Email")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(colors.textPrimary)
                    Text(didSendCode
                        ? String(localized: "Enter the 6-digit code sent to your email.")
                        : String(localized: "Enter the email used for your existing purchase."))
                        .font(.system(size: 14))
                        .foregroundColor(colors.textSecondary)
                }

                VStack(spacing: 14) {
                    TextField("Email", text: $email)
                        #if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled()
                        #endif
                        .textFieldStyle(.roundedBorder)
                        .disabled(didSendCode || restore.inFlight)

                    if didSendCode {
                        TextField("6-digit code", text: $code)
                            #if os(iOS)
                                .keyboardType(.numberPad)
                            #endif
                            .textFieldStyle(.roundedBorder)
                            .disabled(restore.inFlight)
                    }
                }

                if let error = restore.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button {
                    Task { await primaryAction() }
                } label: {
                    HStack(spacing: 8) {
                        if restore.inFlight {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        Text(didSendCode ? String(localized: "Verify") : String(localized: "Send Code"))
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .foregroundColor(.white)
                    .tlingoGlassSurface(.prominent, cornerRadius: TLingoRadius.medium, interactive: true)
                }
                .buttonStyle(.plain)
                .disabled(restore.inFlight)
            }
            .padding(24)
            .background(colors.background.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        onDone()
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .tlingoGlassCapsule(.control, interactive: true)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .tint(colors.accent)
        #if os(macOS)
            .frame(minWidth: 420, minHeight: 320)
        #endif
    }

    private func primaryAction() async {
        if didSendCode {
            let ok = await restore.verifyCode(code)
            if ok {
                onDone()
            }
        } else {
            let ok = await restore.sendCode(email: email)
            if ok {
                didSendCode = true
            }
        }
    }
}
