//
//  NetworkSession.swift
//  ShareCore
//
//  Created by Copilot on 2026/02/28.
//

import Foundation

/// Provides a URLSession configured for the current build environment.
/// Records request metadata for local diagnostics. Body capture is enabled
/// only in developer mode and is bounded and sanitized before persistence.
public enum NetworkSession {
    public static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.protocolClasses = [DebugNetworkProtocol.self] + (config.protocolClasses ?? [])
        return URLSession(configuration: config)
    }()
}
