import Foundation
import SwiftUI

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif

#if os(macOS) || os(iOS)
    public struct RealtimeCaptionColor: Codable, Equatable, Sendable {
        public var red: Double
        public var green: Double
        public var blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        @MainActor
        public init(color: Color) {
            #if os(macOS)
                let resolved = NSColor(color).usingColorSpace(.sRGB) ?? .black
                red = Double(resolved.redComponent)
                green = Double(resolved.greenComponent)
                blue = Double(resolved.blueComponent)
            #else
                var redComponent: CGFloat = 0
                var greenComponent: CGFloat = 0
                var blueComponent: CGFloat = 0
                UIColor(color).getRed(&redComponent, green: &greenComponent, blue: &blueComponent, alpha: nil)
                red = Double(redComponent)
                green = Double(greenComponent)
                blue = Double(blueComponent)
            #endif
        }

        public var color: Color {
            Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        }
    }

    public struct RealtimeCaptionAppearance: Codable, Equatable, Sendable {
        public enum FontDesign: String, Codable, CaseIterable, Identifiable, Sendable {
            case platformDefault
            case serif
            case system
            case rounded

            public var id: String {
                rawValue
            }
        }

        public enum Spacing: String, Codable, CaseIterable, Identifiable, Sendable {
            case compact
            case standard
            case relaxed

            public var id: String {
                rawValue
            }

            public var scale: Double {
                switch self {
                case .compact: 0.5
                case .standard: 1
                case .relaxed: 1.6
                }
            }
        }

        public static let textSizeRange: ClosedRange<Double> = 16 ... 32

        public var fontDesign: FontDesign = Self.defaultFontDesign
        public var textSize: Double = 22
        public var spacing: Spacing = .standard
        public var sourceColor: RealtimeCaptionColor?
        public var translationColor: RealtimeCaptionColor?
        public var backgroundColor: RealtimeCaptionColor?
        public var floatingBackgroundOpacity: Double = 0.48

        public init() {}

        private static var defaultFontDesign: FontDesign {
            #if os(macOS)
                .platformDefault
            #else
                .serif
            #endif
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            fontDesign = try container.decodeIfPresent(FontDesign.self, forKey: .fontDesign) ?? Self.defaultFontDesign
            textSize = try min(max(container.decodeIfPresent(Double.self, forKey: .textSize) ?? 22, 16), 32)
            spacing = try container.decodeIfPresent(Spacing.self, forKey: .spacing) ?? .standard
            sourceColor = try container.decodeIfPresent(RealtimeCaptionColor.self, forKey: .sourceColor)
            translationColor = try container.decodeIfPresent(RealtimeCaptionColor.self, forKey: .translationColor)
            backgroundColor = try container.decodeIfPresent(RealtimeCaptionColor.self, forKey: .backgroundColor)
            floatingBackgroundOpacity = try min(max(
                container.decodeIfPresent(Double.self, forKey: .floatingBackgroundOpacity) ?? 0.48, 0
            ), 1)
        }

        public func sourceTextColor(fallback: Color) -> Color {
            sourceColor?.color ?? fallback
        }

        public func translationTextColor(fallback: Color) -> Color {
            translationColor?.color ?? fallback
        }

        public func captionBackgroundColor(fallback: Color) -> Color {
            backgroundColor?.color ?? fallback
        }
    }
#endif
