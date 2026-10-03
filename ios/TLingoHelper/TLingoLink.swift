import AppKit
import Carbon

/// Finds a TLingo build that accepts popup requests and delivers them to that exact process.
enum TLingoLink {
    static let bundleIdentifier = "com.zanderwang.AITranslator"

    enum Status: Equatable {
        case running(NSRunningApplication)
        case installed(URL)
        case needsUpdate
        case notInstalled
    }

    enum LinkError: LocalizedError {
        case needsUpdate
        case notInstalled
        case processExited

        var errorDescription: String? {
            switch self {
            case .needsUpdate: String(localized: "Update TLingo to use it with TLingoHelper.")
            case .notInstalled: String(localized: "Install TLingo to translate selected text.")
            case .processExited: String(localized: "TLingo quit before the text was sent. Try again.")
            }
        }
    }

    static func status() -> Status {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .filter { !$0.isTerminated }
        if let application = running
            .filter({ $0.bundleURL.map(isCompatible) == true })
            .max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) })
        {
            return .running(application)
        }
        // Direct and older App Store builds share the bundle ID but cannot receive popup requests.
        guard running.isEmpty else { return .needsUpdate }
        let installations = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleIdentifier)
        if let url = installations.filter(isCompatible).min(by: { rank($0) < rank($1) }) {
            return .installed(url)
        }
        return installations.isEmpty ? .notInstalled : .needsUpdate
    }

    /// Returns the receiving process, launching TLingo in the background when it is not running.
    static func targetApplication() async throws -> NSRunningApplication {
        switch status() {
        case let .running(application):
            return application
        case let .installed(url):
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.arguments = ["-TLingoTextPopupLaunch"]
            return try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        case .needsUpdate:
            throw LinkError.needsUpdate
        case .notInstalled:
            throw LinkError.notInstalled
        }
    }

    static func send(_ command: TextPopupRequest.Command, to application: NSRunningApplication) throws {
        guard !application.isTerminated else { throw LinkError.processExited }
        let url = try TextPopupRequest.url(for: command)
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kInternetEventClass),
            eventID: AEEventID(kAEGetURL),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: application.processIdentifier),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
        // Targeting the PID delivers the URL without activating TLingo.
        _ = try event.sendEvent(options: [.noReply, .neverInteract, .dontRecord], timeout: 1)
    }

    /// Brings up TLingo's main window, launching it if needed.
    static func openTLingo() {
        let url: URL? = switch status() {
        case let .running(application): application.bundleURL
        case let .installed(url): url
        case .needsUpdate, .notInstalled: NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        }
        guard let url else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func isCompatible(_ url: URL) -> Bool {
        Bundle(url: url)?.object(forInfoDictionaryKey: TextPopupRequest.capabilityKey) as? Int
            == TextPopupRequest.protocolVersion
    }

    /// Prefers installed copies over build products registered with Launch Services.
    private static func rank(_ url: URL) -> Int {
        let path = url.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        if path.hasPrefix("/Applications/") { return 0 }
        if path.hasPrefix(userApplications + "/") { return 1 }
        return 2
    }
}
