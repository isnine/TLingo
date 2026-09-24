//
//  OAuthActivationDiagnostics.swift
//  ShareCore
//

import Foundation

/// Compact activation diagnostics surfaced in support emails when OAuth
/// activation fails. Stripe IDs / plan / status are deliberately omitted —
/// in every failure mode we've seen those fields are empty because the
/// entitlement row is missing or attached to the wrong user; showing a
/// wall of `-` confuses users and adds no signal. Email + Supabase User ID
/// give support enough to reconstruct the full picture from Stripe /
/// Supabase in seconds.
public struct OAuthActivationDiagnostics: Codable, Equatable {
    public let email: String
    public let userID: String
    public let isPremium: Bool
    public let errorCode: String?
    public let errorDescription: String?
    public let activationURL: URL?
    public let callbackURL: URL?
    public let appVersion: String
    public let buildNumber: String
    public let operatingSystemVersion: String

    public init(
        email: String,
        userID: String,
        isPremium: Bool,
        errorCode: String?,
        errorDescription: String?,
        activationURL: URL?,
        callbackURL: URL?,
        appVersion: String = Self.currentAppVersion,
        buildNumber: String = Self.currentBuildNumber,
        operatingSystemVersion: String = ProcessInfo.processInfo.operatingSystemVersionString
    ) {
        self.email = email
        self.userID = userID
        self.isPremium = isPremium
        self.errorCode = errorCode
        self.errorDescription = errorDescription
        self.activationURL = activationURL
        self.callbackURL = callbackURL
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.operatingSystemVersion = operatingSystemVersion
    }

    public var feedbackMailtoURL: URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "iamzanderwang@outlook.com"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "TLingo Direct activation issue"),
            URLQueryItem(name: "body", value: feedbackBody),
        ]
        return components.url
    }

    public func withError(code: String?, description: String?, callbackURL: URL? = nil) -> OAuthActivationDiagnostics {
        OAuthActivationDiagnostics(
            email: email,
            userID: userID,
            isPremium: isPremium,
            errorCode: code,
            errorDescription: description,
            activationURL: activationURL,
            callbackURL: callbackURL ?? self.callbackURL,
            appVersion: appVersion,
            buildNumber: buildNumber,
            operatingSystemVersion: operatingSystemVersion
        )
    }

    public var feedbackBody: String {
        let rows: [(String, String?)] = [
            ("Summary", "Please describe what happened here:"),
            ("Error Code", errorCode),
            ("Error Description", errorDescription),
            ("Email", emptyToNil(email)),
            ("Supabase User ID", emptyToNil(userID)),
            ("Is Premium", String(isPremium)),
            ("Activation URL", activationURL?.absoluteString),
            ("Callback URL", redactedCallbackURL),
            ("App Version", "\(appVersion) (\(buildNumber))"),
            ("System", operatingSystemVersion),
            ("Generated At", ISO8601DateFormatter().string(from: Date())),
        ]

        return rows
            .map { key, value in "\(key): \(value?.isEmpty == false ? value! : "-")" }
            .joined(separator: "\n")
    }

    private var redactedCallbackURL: String? {
        guard var components = callbackURL.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else {
            return nil
        }
        components.queryItems = components.queryItems?.map { item in
            if item.name == "code" {
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
            return item
        }
        return components.url?.absoluteString
    }

    public static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    public static var currentBuildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    private func emptyToNil(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}

public struct OAuthActivationIssue: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let message: String
    public let diagnostics: OAuthActivationDiagnostics

    public init(
        id: String = UUID().uuidString,
        title: String,
        message: String,
        diagnostics: OAuthActivationDiagnostics
    ) {
        self.id = id
        self.title = title
        self.message = message
        self.diagnostics = diagnostics
    }
}
