//
//  ImageAttachment.swift
//  ShareCore
//
//  Created by AITranslator on 2025/02/07.
//

import Foundation
import SwiftUI
import os

#if canImport(UIKit)
    import UIKit
    public typealias PlatformImage = UIImage
#endif
#if canImport(AppKit)
    import AppKit
    public typealias PlatformImage = NSImage
#endif

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ImageAttachment")

/// Represents an image attached to a translation request for multimodal LLM input.
public struct ImageAttachment: Identifiable, Sendable {
    public let id: UUID
    /// JPEG-compressed image data (resized to fit within maxDimension)
    public let imageData: Data
    /// Original image dimensions before compression
    public let originalSize: CGSize
    /// Pre-computed data URL suitable for OpenAI vision API: `data:image/jpeg;base64,...`
    public let base64DataURL: String

    /// Maximum dimension (width or height) for resizing before sending to LLM
    public static let maxDimension: CGFloat = 2048
    /// JPEG compression quality
    public static let compressionQuality: CGFloat = 0.8

    public init(id: UUID = UUID(), imageData: Data, originalSize: CGSize) {
        self.id = id
        self.imageData = imageData
        self.originalSize = originalSize
        self.base64DataURL = "data:image/jpeg;base64,\(imageData.base64EncodedString())"
    }

    /// Estimated size in megabytes
    public var sizeMB: Double {
        Double(imageData.count) / (1024 * 1024)
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        /// Creates an ImageAttachment from an NSImage, resizing and compressing automatically.
        public static func from(nsImage: NSImage) -> ImageAttachment? {
            // Try multiple approaches to get a CGImage from NSImage
            let cgImage: CGImage? = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
                ?? {
                    // Fallback: render NSImage into a bitmap context to get CGImage
                    logger.error("cgImage(forProposedRect:) returned nil, trying NSBitmapImageRep fallback")
                    guard let tiffData = nsImage.tiffRepresentation,
                          let bitmapRep = NSBitmapImageRep(data: tiffData)
                    else {
                        logger.error("NSBitmapImageRep fallback also failed")
                        return nil
                    }
                    return bitmapRep.cgImage
                }()

            guard let cgImage else {
                logger.error("Failed to extract CGImage from NSImage (size: \(nsImage.size.debugDescription, privacy: .public))")
                return nil
            }

            let originalWidth = CGFloat(cgImage.width)
            let originalHeight = CGFloat(cgImage.height)
            let originalSize = CGSize(width: originalWidth, height: originalHeight)
            logger.debug("Extracted CGImage: \(Int(originalWidth), privacy: .public)x\(Int(originalHeight), privacy: .public), bitsPerComponent: \(cgImage.bitsPerComponent, privacy: .public), alphaInfo: \(cgImage.alphaInfo.rawValue, privacy: .public)")

            let resizedImage = resizeIfNeeded(
                cgImage: cgImage,
                originalWidth: originalWidth,
                originalHeight: originalHeight
            )

            guard let jpegData = jpegData(from: resizedImage) else {
                logger.error("JPEG conversion failed for CGImage \(Int(originalWidth), privacy: .public)x\(Int(originalHeight), privacy: .public)")
                return nil
            }

            logger.debug("ImageAttachment created: \(Int(originalWidth), privacy: .public)x\(Int(originalHeight), privacy: .public), JPEG size: \(String(format: "%.2f", Double(jpegData.count) / 1024), privacy: .public)KB")
            return ImageAttachment(imageData: jpegData, originalSize: originalSize)
        }
    #endif

    #if canImport(UIKit)
        /// Creates an ImageAttachment from a UIImage, resizing and compressing automatically.
        public static func from(uiImage: UIImage) -> ImageAttachment? {
            guard let cgImage = uiImage.cgImage else {
                return nil
            }

            let originalWidth = CGFloat(cgImage.width)
            let originalHeight = CGFloat(cgImage.height)
            let originalSize = CGSize(width: originalWidth, height: originalHeight)

            let resizedImage = resizeIfNeeded(
                cgImage: cgImage,
                originalWidth: originalWidth,
                originalHeight: originalHeight
            )

            let uiResized = UIImage(cgImage: resizedImage)
            guard let jpegData = uiResized.jpegData(compressionQuality: compressionQuality) else {
                return nil
            }

            return ImageAttachment(imageData: jpegData, originalSize: originalSize)
        }

        /// Create a SwiftUI Image for thumbnail preview
        public var thumbnailImage: Image {
            if let uiImage = UIImage(data: imageData) {
                return Image(uiImage: uiImage)
            }
            return Image(systemName: "photo")
        }
    #endif

    // MARK: - Private Helpers

    /// Resize CGImage if either dimension exceeds maxDimension, preserving aspect ratio.
    private static func resizeIfNeeded(
        cgImage: CGImage,
        originalWidth: CGFloat,
        originalHeight: CGFloat
    ) -> CGImage {
        let maxDim = maxDimension
        guard originalWidth > maxDim || originalHeight > maxDim else {
            return cgImage
        }

        let scale: CGFloat
        if originalWidth > originalHeight {
            scale = maxDim / originalWidth
        } else {
            scale = maxDim / originalHeight
        }

        let newWidth = Int(originalWidth * scale)
        let newHeight = Int(originalHeight * scale)

        logger.debug("Resizing image from \(Int(originalWidth), privacy: .public)x\(Int(originalHeight), privacy: .public) to \(newWidth, privacy: .public)x\(newHeight, privacy: .public)")

        // Use a safe bitmapInfo that works for all source images (premultiplied alpha with skip)
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        let safeBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        guard
            let context = CGContext(
                data: nil,
                width: newWidth,
                height: newHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: safeBitmapInfo.rawValue
            )
        else {
            logger.error("CGContext creation failed during resize")
            return cgImage
        }

        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: newWidth, height: newHeight))

        return context.makeImage() ?? cgImage
    }

    /// Strip alpha channel from CGImage by drawing onto an opaque white background.
    /// This is required before JPEG conversion since JPEG doesn't support transparency.
    private static func stripAlpha(from cgImage: CGImage) -> CGImage? {
        let width = cgImage.width
        let height = cgImage.height
        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        // noneSkipLast = opaque context (no alpha), compatible with JPEG
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            logger.error("stripAlpha: CGContext creation failed")
            return nil
        }

        // Fill white background (so transparent areas become white, not black)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return context.makeImage()
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        /// Create a SwiftUI Image for thumbnail preview (macOS)
        public var thumbnailImage: Image {
            if let nsImage = NSImage(data: imageData) {
                return Image(nsImage: nsImage)
            }
            return Image(systemName: "photo")
        }

        /// Convert CGImage to JPEG Data on macOS, stripping alpha channel first since JPEG doesn't support it.
        private static func jpegData(from cgImage: CGImage) -> Data? {
            // Strip alpha by drawing into an opaque context first
            let opaqueImage = stripAlpha(from: cgImage) ?? cgImage
            let bitmapRep = NSBitmapImageRep(cgImage: opaqueImage)
            return bitmapRep.representation(
                using: .jpeg,
                properties: [.compressionFactor: compressionQuality]
            )
        }
    #endif
}
