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
    /// Frames reuse the in-app caption text and palette, so both surfaces show the same captions.
    @MainActor
    final class RealtimePictureInPictureController: NSObject, ObservableObject {
        /// Lines beyond what fits are clipped at the top, matching the bottom-pinned in-app list.
        private static let captionLineLimit = 12
        private static let renderScale: CGFloat = 3
        /// Caps the canvas on iPad so captions stay legible in the small PiP window.
        private static let maxRenderWidth: CGFloat = 430

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
                .combineLatest(store.$isPaused, store.$isRunning, preferences.$accentTheme)
                .receive(on: RunLoop.main)
                .sink { [weak self] lines, isPaused, isRunning, _ in
                    self?.render(lines: lines, isPaused: isPaused, isRunning: isRunning)
                }
                .store(in: &cancellables)

            displayView.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { [weak self] (_: SampleBufferDisplayView, _) in
                guard let self else { return }
                render(lines: self.store.captionLines, isPaused: self.store.isPaused, isRunning: self.store.isRunning)
            }

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

        private func render(lines: [RealtimeCaptionLine], isPaused: Bool, isRunning: Bool) {
            isPlaybackPaused.store(isPaused, ordering: .relaxed)
            pictureInPictureController?.invalidatePlaybackState()

            let colorScheme: ColorScheme = displayView.traitCollection.userInterfaceStyle == .dark ? .dark : .light
            let palette = AppColors.palette(for: colorScheme)
            let style = RealtimeCaptionTextView.Style(palette: palette)
            let visibleLines = Array(lines.suffix(Self.captionLineLimit))
            let width = min(displayView.window?.bounds.width ?? 393, Self.maxRenderWidth)
            let frame = Frame(
                size: CGSize(width: width, height: (width / 2).rounded()),
                background: UIColor(palette.background),
                captions: RealtimeCaptionTextView.attributedText(for: visibleLines, style: style),
                placeholder: visibleLines.isEmpty
                    ? Self.placeholderText(RealtimeCaptionDisplay.emptyPlaceholderText(isRunning: isRunning), style: style)
                    : nil
            )
            guard let sampleBuffer = Self.makeSampleBuffer(frame: frame) else { return }
            let renderer = displayView.sampleBufferDisplayLayer.sampleBufferRenderer
            if renderer.status == .failed {
                renderer.flush()
            }
            renderer.enqueue(sampleBuffer)
        }

        private struct Frame {
            /// Canvas size in points; drawn at `renderScale`.
            var size: CGSize
            var background: UIColor
            var captions: NSAttributedString
            var placeholder: NSAttributedString?
        }

        private static func placeholderText(_ text: String, style: RealtimeCaptionTextView.Style) -> NSAttributedString {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            return NSAttributedString(string: text, attributes: [
                .font: UIFont.systemFont(ofSize: 17, weight: .semibold),
                .foregroundColor: style.sourceColor,
                .paragraphStyle: paragraph,
            ])
        }

        private static func makeSampleBuffer(frame: Frame) -> CMSampleBuffer? {
            let pixelWidth = Int(frame.size.width * renderScale)
            let pixelHeight = Int(frame.size.height * renderScale)
            let attributes = [
                kCVPixelBufferCGImageCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ] as CFDictionary
            var pixelBuffer: CVPixelBuffer?
            guard CVPixelBufferCreate(
                kCFAllocatorDefault,
                pixelWidth,
                pixelHeight,
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
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else {
                return nil
            }

            // UIKit text drawing expects a top-left origin in points.
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: renderScale, y: -renderScale)
            UIGraphicsPushContext(context)
            let bounds = CGRect(origin: .zero, size: frame.size)
            frame.background.setFill()
            context.fill(bounds)

            let drawOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            if let placeholder = frame.placeholder {
                let textBounds = bounds.insetBy(dx: RealtimeCaptionTextView.horizontalPadding, dy: 0)
                let height = placeholder.boundingRect(
                    with: CGSize(width: textBounds.width, height: .greatestFiniteMagnitude),
                    options: drawOptions,
                    context: nil
                ).height.rounded(.up)
                placeholder.draw(
                    with: CGRect(x: textBounds.minX, y: textBounds.midY - height / 2, width: textBounds.width, height: height),
                    options: drawOptions,
                    context: nil
                )
            } else {
                // Same insets as the in-app list; the newest caption sits at the bottom and older lines clip off the top.
                let textRect = bounds.inset(by: UIEdgeInsets(
                    top: RealtimeCaptionTextView.topPadding,
                    left: RealtimeCaptionTextView.horizontalPadding,
                    bottom: RealtimeCaptionTextView.bottomPadding,
                    right: RealtimeCaptionTextView.horizontalPadding
                ))
                let textHeight = frame.captions.boundingRect(
                    with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude),
                    options: drawOptions,
                    context: nil
                ).height.rounded(.up)
                context.clip(to: textRect)
                frame.captions.draw(
                    with: CGRect(x: textRect.minX, y: textRect.maxY - textHeight, width: textRect.width, height: textHeight),
                    options: drawOptions,
                    context: nil
                )
            }
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
