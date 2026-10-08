//
//  ClientUserAgent.swift
//  ShareCore
//
//  `User-Agent` for TLingo requests, e.g.
//  `TLingo/3.8.4 (504; iOS 26.1; iPhone17,3; AppStore)`. The Worker forwards it
//  to the AI gateway logs so each request shows the release, OS, device model,
//  and distribution channel.
//

import Foundation

enum ClientUserAgent {
    static let value: String = {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "TLingo/\(version) (\(build); \(platform) \(osVersion); \(deviceModel); \(channel))"
    }()

    private static var platform: String {
        #if os(macOS)
            return "macOS"
        #else
            if ProcessInfo.processInfo.isiOSAppOnMac { return "iOSAppOnMac" }
            #if targetEnvironment(macCatalyst)
                return "macCatalyst"
            #else
                return "iOS"
            #endif
        #endif
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(version.majorVersion).\(version.minorVersion)"
        return version.patchVersion > 0 ? "\(base).\(version.patchVersion)" : base
    }

    /// Hardware identifier such as `iPhone17,3` or `Mac15,6`.
    private static var deviceModel: String {
        #if targetEnvironment(simulator)
            return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "Simulator"
        #else
            #if os(macOS) || targetEnvironment(macCatalyst)
                let key = "hw.model"
            #else
                let key = ProcessInfo.processInfo.isiOSAppOnMac ? "hw.model" : "hw.machine"
            #endif
            var size = 0
            guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return "unknown" }
            return String(cString: buffer)
        #endif
    }

    private static var channel: String {
        #if DEBUG
            return "Debug"
        #else
            if BuildEnvironment.isDirectDistribution { return "Direct" }
            // A macOS TestFlight install is only recognized from its second
            // launch, after StoreManager has persisted the AppTransaction probe.
            return DeveloperMode.isLikelyTestFlight ? "TestFlight" : "AppStore"
        #endif
    }
}
