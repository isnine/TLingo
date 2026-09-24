import Foundation

public enum PasteboardHelper {
    public static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #elseif canImport(AppKit)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        NotificationCenter.default.post(name: .didCopyFromApp, object: nil)
        #endif
    }
}

extension Notification.Name {
    /// Posted after the app copies content to the pasteboard.
    /// ClipboardMonitor observes this to avoid treating the copy as external content.
    public static let didCopyFromApp = Notification.Name("com.tlingo.didCopyFromApp")
}

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if os(macOS)
import UniformTypeIdentifiers

extension NSPasteboard {
    private static let imageDataTypes: [NSPasteboard.PasteboardType] = [.tiff, .png, NSPasteboard.PasteboardType("public.jpeg")]
    private static let imageURLOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    var containsImage: Bool {
        canReadObject(forClasses: [NSURL.self], options: Self.imageURLOptions)
            || availableType(from: Self.imageDataTypes) != nil
    }

    func imageFromData() -> NSImage? {
        guard let availableType = availableType(from: Self.imageDataTypes),
              let data = data(forType: availableType)
        else {
            return nil
        }
        return NSImage(data: data)
    }

    func imagesFromFileURLs() -> [NSImage] {
        guard let urls = readObjects(forClasses: [NSURL.self], options: Self.imageURLOptions) as? [URL] else {
            return []
        }
        return urls.compactMap { NSImage(contentsOf: $0) }
    }
}
#endif
