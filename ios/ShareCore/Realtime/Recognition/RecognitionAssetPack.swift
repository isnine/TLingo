import BackgroundAssets
import Foundation
import System

/// A recognition model hosted by Apple as a Background Assets asset pack.
/// `scripts/build_asset_packs.sh` packages the same IDs and directory layout.
public struct RecognitionAssetPack: Sendable, Equatable {
    public let id: String
    /// Relative directory inside the shared asset-pack namespace that holds the model files.
    public let directory: String
    public let sizeDisplayName: String

    /// Parakeet Unified 0.6B with the [70, 7, 7] (1120 ms) streaming encoder. iOS ships the fp16
    /// encoder because the int8 one cannot build an execution plan on A16 (FluidAudio #828).
    public static let parakeetUnified: RecognitionAssetPack = {
        #if os(macOS)
            RecognitionAssetPack(id: "ParakeetUnifiedEN-macOS", directory: "ParakeetUnifiedEN", sizeDisplayName: "580.6 MiB")
        #else
            RecognitionAssetPack(id: "ParakeetUnifiedEN-iOS", directory: "ParakeetUnifiedEN", sizeDisplayName: "1.11 GiB")
        #endif
    }()

    public var isAvailableLocally: Bool {
        if #available(iOS 26.4, macOS 26.4, *) {
            return AssetPackManager.shared.assetPackIsAvailableLocally(withID: id)
        }
        guard let url = try? directoryURL() else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    public func directoryURL() throws -> URL {
        try AssetPackManager.shared.url(for: FilePath(directory))
    }

    /// Downloads the pack if needed, reporting the system download progress.
    public func ensureLocalAvailability(progress: @escaping @Sendable (Double) -> Void) async throws {
        let manager = AssetPackManager.shared
        let assetPack = try await manager.assetPack(withID: id)
        let activeProgress = ActiveProgress()
        let updates = Task {
            for await update in manager.statusUpdates(forAssetPackWithID: id) {
                guard case let .downloading(_, downloadProgress) = update else { continue }
                activeProgress.set(downloadProgress)
                progress(downloadProgress.fractionCompleted)
            }
        }
        defer { updates.cancel() }
        try await withTaskCancellationHandler {
            try await manager.ensureLocalAvailability(of: assetPack)
        } onCancel: {
            activeProgress.cancel()
        }
    }

    public func remove() async throws {
        try await AssetPackManager.shared.remove(assetPackWithID: id)
    }
}

/// Background Assets cancels a download through the `Progress` it reports, not task cancellation.
private final class ActiveProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var progress: Progress?
    private var isCancelled = false

    func set(_ progress: Progress) {
        let shouldCancel = lock.withLock {
            self.progress = progress
            return isCancelled
        }
        if shouldCancel {
            progress.cancel()
        }
    }

    func cancel() {
        lock.withLock {
            isCancelled = true
            return progress
        }?.cancel()
    }
}
