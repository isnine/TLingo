//
//  DeepLink.swift
//  ShareCore
//

import Foundation

/// Constants and helpers for the `tlingo://` and `tlingo-direct://` deep
/// link schemes.
///
/// - `tlingo://translate` — share-extension / shortcuts entry, App Store target.
/// - `tlingo://realtime` — App Store event / campaign entry for realtime translation.
/// - `tlingo-direct://oauth/callback` — OAuth activation return target,
///   handled by `OAuthCoordinator.handleCallbackIfMatching` in the
///   Direct macOS build. Uses a distinct scheme so macOS Launch Services
///   can't route the callback to the App Store TLingo (both apps share
///   the bundle id and would otherwise both register `tlingo://`).
public enum DeepLink {
    public static let scheme = "tlingo"
    public static let directScheme = "tlingo-direct"
    public static let translateHost = "translate"
    public static let realtimeHost = "realtime"

    public enum QueryParam {
        public static let text = "text"
        public static let action = "action"
        public static let config = "config"
    }

    public enum NotificationKey {
        public static let text = "text"
        public static let actionName = "actionName"
        public static let configName = "configName"
    }

    /// Builds a `tlingo://translate?text=...&action=<name>&config=<name>` URL.
    public static func translateURL(text: String, actionName: String? = nil, configName: String? = nil) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = translateHost
        components.queryItems = [URLQueryItem(name: QueryParam.text, value: text)]
        if let actionName {
            components.queryItems?.append(URLQueryItem(name: QueryParam.action, value: actionName))
        }
        if let configName {
            components.queryItems?.append(URLQueryItem(name: QueryParam.config, value: configName))
        }
        return components.url
    }

    /// Parses a `tlingo://translate` URL, returning the text, optional action name, and optional config name.
    public static func parse(_ url: URL) -> (text: String, actionName: String?, configName: String?)? {
        guard url.scheme == scheme, url.host == translateHost else { return nil }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let text = components.queryItems?.first(where: { $0.name == QueryParam.text })?.value,
              !text.isEmpty
        else { return nil }
        let actionName = components.queryItems?
            .first(where: { $0.name == QueryParam.action })?.value
        let configName = components.queryItems?
            .first(where: { $0.name == QueryParam.config })?.value
        return (text, actionName, configName)
    }

    public static func isRealtimeURL(_ url: URL) -> Bool {
        url.scheme == scheme && url.host == realtimeHost
    }
}

public extension Notification.Name {
    static let deepLinkRealtimeRequested = Notification.Name("deepLinkRealtimeRequested")
}
