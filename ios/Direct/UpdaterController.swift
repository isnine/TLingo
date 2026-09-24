//
//  UpdaterController.swift
//  TLingo-Direct
//
//  Sparkle 2 wrapper. Compiled only into the Direct target — App Store builds
//  must not link Sparkle (Guideline 2.4.5).
//

#if DIRECT_DISTRIBUTION

    import Combine
    import os
    import Sparkle
    import SwiftUI

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "Updater")

    @MainActor
    public final class UpdaterController: ObservableObject {
        public static let shared = UpdaterController()

        public struct AvailableUpdate: Equatable {
            public let displayVersionString: String
            public let versionString: String

            public var displayVersion: String {
                let trimmedDisplayVersion = displayVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedDisplayVersion.isEmpty {
                    return trimmedDisplayVersion
                }
                return versionString
            }

            public var fullVersionDescription: String {
                if displayVersion == versionString {
                    return displayVersion
                }
                return "\(displayVersion) (build \(versionString))"
            }
        }

        @Published public private(set) var canCheckForUpdates = false
        @Published public private(set) var availableUpdate: AvailableUpdate?

        private let controller: SPUStandardUpdaterController
        private let updaterDelegate: UpdaterDelegate
        private var observation: AnyCancellable?

        private init() {
            let updaterDelegate = UpdaterDelegate()
            self.updaterDelegate = updaterDelegate
            controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: updaterDelegate,
                userDriverDelegate: nil
            )
            updaterDelegate.owner = self

            observation = controller.updater
                .publisher(for: \.canCheckForUpdates)
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.canCheckForUpdates = $0 }

            // Diagnostic: confirm Sparkle picked up the feed URL & EdDSA key from
            // Info.plist. If either is missing, auto-update silently no-ops.
            let bundle = Bundle.main
            let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "<missing>"
            let hasKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.isEmpty == false
            let version = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
            logger
                .info(
                    """
                    Sparkle ready: feed=\(feed, privacy: .public) \
                    hasKey=\(hasKey, privacy: .public) \
                    build=\(version, privacy: .public)
                    """
                )
        }

        public func checkForUpdates() {
            controller.checkForUpdates(nil)
        }

        public func checkForUpdateInformationIfAllowed() {
            guard controller.updater.automaticallyChecksForUpdates else {
                logger.debug("Skipping update information check because automatic checks are disabled")
                return
            }

            guard !controller.updater.sessionInProgress else {
                logger.debug("Skipping update information check because an update session is already in progress")
                return
            }

            controller.updater.checkForUpdateInformation()
        }

        fileprivate func didFindValidUpdate(_ item: SUAppcastItem) {
            let update = AvailableUpdate(
                displayVersionString: item.displayVersionString,
                versionString: item.versionString
            )
            availableUpdate = update
            logger.info("Sparkle found update: \(update.fullVersionDescription, privacy: .public)")
        }

        fileprivate func didNotFindUpdate(_ error: Error) {
            availableUpdate = nil
            logger.info("Sparkle did not find an update: \(error.localizedDescription, privacy: .public)")
        }

        fileprivate func didAbortWithError(_ error: Error) {
            logger.error("Sparkle update check failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @MainActor
    private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
        weak var owner: UpdaterController?

        func updater(_: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
            owner?.didFindValidUpdate(item)
        }

        func updaterDidNotFindUpdate(_: SPUUpdater, error: Error) {
            owner?.didNotFindUpdate(error)
        }

        func updater(_: SPUUpdater, didAbortWithError error: Error) {
            owner?.didAbortWithError(error)
        }
    }

    public struct CheckForUpdatesView: View {
        @ObservedObject private var updater = UpdaterController.shared

        public init() {}

        public var body: some View {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }

#endif
