#if os(iOS)
    import AVFoundation
    import AVKit
    import Combine
    import os
    import ShareCore
    import Synchronization
    import SwiftUI
    import UIKit

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "RealtimePiP")

    /// Mirrors realtime microphone captions into a Picture in Picture window when the app moves to the background.
    /// PiP only shows video, so each caption change is drawn into a frame and enqueued on a sample buffer layer.
    @MainActor
    final class RealtimePictureInPictureController: NSObject, ObservableObject {
        private static let renderSize = CGSize(width: 1280, height: 640)
        private static let captionLineLimit = 4

        let displayView = SampleBufferDisplayView()
        private let store: RealtimeSessionStore
        private let preferences: AppPreferences
        private var pictureInPictureController: AVPictureInPictureController?
        private var cancellables: Set<AnyCancellable> = []
        private let isPlaybackPaused = Atomic<Bool>(false)

        init(store: RealtimeSessionStore, preferences: AppPreferences = .shared) {
            self.store = store
            self.preferences = preferences
            super.init()
            guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

            let contentSource = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: displayView.sampleBufferDisplayLayer,
                playbackDelegate: self
            )
            let controller = AVPictureInPictureController(contentSource: contentSource)
            controller.delegate = self
            controller.requiresLinearPlayback = true
            pictureInPictureController = controller

            store.$captionLines
                .combineLatest(store.$isPaused, store.$statusText)
                .receive(on: RunLoop.main)
                .sink { [weak self] lines, isPaused, statusText in
                    self?.render(lines: lines, isPaused: isPaused, statusText: statusText)
                }
                .store(in: &cancellables)

            // Only a live, unpaused microphone session moves into PiP; a paused session stops in the background.
            store.$isRunning
                .combineLatest(store.$isPaused, store.$inputSource, preferences.$realtimePictureInPictureEnabled)
                .receive(on: RunLoop.main)
                .sink { [weak self] isRunning, isPaused, inputSource, isEnabled in
                    let isAvailable = isEnabled && isRunning && inputSource == .microphone
                    self?.pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline =
                        isAvailable && !isPaused
                    // Pausing from the PiP window keeps it open.
                    if !isAvailable {
                        self?.stopPictureInPicture()
                    }
                }
                .store(in: &cancellables)

            // Returning to the app by any route other than the PiP restore button leaves PiP open.
            NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
                .sink { [weak self] _ in
                    self?.stopPictureInPicture()
                }
                .store(in: &cancellables)
        }

        private func stopPictureInPicture() {
            guard let pictureInPictureController, pictureInPictureController.isPictureInPictureActive else { return }
            pictureInPictureController.stopPictureInPicture()
        }

        private func render(lines: [RealtimeCaptionLine], isPaused: Bool, statusText: String) {
            isPlaybackPaused.store(isPaused, ordering: .relaxed)
            pictureInPictureController?.invalidatePlaybackState()

            var visibleLines = lines.suffix(Self.captionLineLimit)
            // Start at a source line so each translation stays under its own source.
            if visibleLines.contains(where: { $0.kind == .source }) {
                while visibleLines.first?.kind == .translation {
                    visibleLines.removeFirst()
                }
            }
            let text = Self.captionText(lines: Array(visibleLines), placeholder: statusText)
            guard let sampleBuffer = Self.makeSampleBuffer(text: text, size: Self.renderSize) else { return }
            let renderer = displayView.sampleBufferDisplayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }

        private static func captionText(lines: [RealtimeCaptionLine], placeholder: String) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.paragraphSpacing = 14

            guard !lines.isEmpty else {
                return NSAttributedString(string: placeholder, attributes: [
                    .font: UIFont.systemFont(ofSize: 44, weight: .medium),
                    .foregroundColor: UIColor.white.withAlphaComponent(0.6),
                    .paragraphStyle: paragraph,
                ])
            }

            let text = NSMutableAttributedString()
            for (index, line) in lines.enumerated() {
                let isSource = line.kind == .source
                let color: UIColor = line.isPending
                    ? .systemTeal
                    : isSource ? UIColor.white.withAlphaComponent(0.65) : .white
                text.append(NSAttributedString(
                    string: index == lines.count - 1 ? line.text : line.text + "\n",
                    attributes: [
                        .font: UIFont.systemFont(ofSize: isSource ? 40 : 52, weight: isSource ? .medium : .semibold),
                        .foregroundColor: color,
                        .paragraphStyle: paragraph,
                    ]
                ))
            }
            return text
        }

        private static func makeSampleBuffer(text: NSAttributedString, size: CGSize) -> CMSampleBuffer? {
            let attributes = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(size.width),
                Int(size.height),
                kCVPixelFormatType_32BGRA,
                attributes,
                &pixelBuffer
            ) == kCVReturnSuccess, let pixelBuffer else {
                return nil
            }

            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
            guard let context = CGContext(
                data: CVPixelBufferGetBaseAddress(pixelBuffer),
                width: Int(size.width),
                height: Int(size.height),
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                return nil
            }

            // UIKit text drawing expects a top-left origin.
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: 1, y: -1)
            UIGraphicsPushContext(context)
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))

            // Anchor the newest caption to the bottom; older lines clip off the top.
            let textRect = CGRect(origin: .zero, size: size).insetBy(dx: 48, dy: 36)
            let textHeight = text.boundingRect(
                with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height.rounded(.up)
            context.clip(to: textRect)
            text.draw(
                with: CGRect(x: textRect.minX, y: textRect.maxY - textHeight, width: textRect.width, height: textHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            )
            UIGraphicsPopContext()

            var formatDescription: CMVideoFormatDescription?
            guard CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &formatDescription
            ) == noErr, let formatDescription else {
                return nil
            }
            var timing = CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                decodeTimeStamp: .invalid
            )
            var sampleBuffer: CMSampleBuffer?
            guard CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: formatDescription,
                sampleTiming: &timing,
                sampleBufferOut: &sampleBuffer
            ) == noErr, let sampleBuffer else {
                return nil
            }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0
            {
                let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(
                    attachment,
                    Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                    Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
                )
            }
            return sampleBuffer
        }
    }

    extension RealtimePictureInPictureController: AVPictureInPictureControllerDelegate {
        nonisolated func pictureInPictureControllerWillStartPictureInPicture(_: AVPictureInPictureController) {
            MainActor.assumeIsolated {
                store.continuesInBackground = true
            }
        }

        nonisolated func pictureInPictureController(
            _: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            MainActor.assumeIsolated {
                logger.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
                store.continuesInBackground = false
            }
        }

        nonisolated func pictureInPictureControllerDidStopPictureInPicture(_: AVPictureInPictureController) {
            MainActor.assumeIsolated {
                store.continuesInBackground = false
                // Closing the PiP window from another app ends the session instead of recording invisibly.
                guard UIApplication.shared.applicationState == .background, store.isRunning else { return }
                Task { await store.stop() }
            }
        }
    }

    extension RealtimePictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
        nonisolated func pictureInPictureController(_: AVPictureInPictureController, setPlaying playing: Bool) {
            Task { @MainActor in
                guard store.isRunning, store.isPaused == playing else { return }
                store.togglePaused()
            }
        }

        nonisolated func pictureInPictureControllerTimeRangeForPlayback(_: AVPictureInPictureController) -> CMTimeRange {
            // An infinite range presents the content as live, without a scrubber.
            CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }

        nonisolated func pictureInPictureControllerIsPlaybackPaused(_: AVPictureInPictureController) -> Bool {
            isPlaybackPaused.load(ordering: .relaxed)
        }

        nonisolated func pictureInPictureController(
            _: AVPictureInPictureController,
            didTransitionToRenderSize _: CMVideoDimensions
        ) {}

        nonisolated func pictureInPictureController(
            _: AVPictureInPictureController,
            skipByInterval _: CMTime,
            completion completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }
    }

    final class SampleBufferDisplayView: UIView {
        override class var layerClass: AnyClass {
            AVSampleBufferDisplayLayer.self
        }

        var sampleBufferDisplayLayer: AVSampleBufferDisplayLayer {
            layer as! AVSampleBufferDisplayLayer
        }
    }

    /// Hosts the PiP source layer inline; PiP can only start from a layer that is in the window hierarchy.
    struct RealtimePictureInPictureSourceView: UIViewRepresentable {
        let controller: RealtimePictureInPictureController

        func makeUIView(context _: Context) -> SampleBufferDisplayView {
            controller.displayView
        }

        func updateUIView(_: SampleBufferDisplayView, context _: Context) {}
    }
#endif
