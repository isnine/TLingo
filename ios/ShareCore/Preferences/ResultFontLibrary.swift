import Combine
import CoreText
import Foundation
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

final class ResultFontLibrary: ObservableObject {
    static let shared = ResultFontLibrary()
    static let styleKey = "resultReadingStyle"
    static let textSizeRange: ClosedRange<Double> = 11 ... 28

    @Published var style: ResultReadingStyle {
        didSet {
            if let data = try? JSONEncoder().encode(style) {
                defaults.set(data, forKey: Self.styleKey)
            }
        }
    }

    @Published private(set) var fonts: [ImportedResultFont] = []

    private let defaults: UserDefaults
    private let directory: URL

    init(
        defaults: UserDefaults = AppPreferences.sharedDefaults,
        directory: URL? = nil
    ) {
        self.defaults = defaults
        #if os(iOS)
            let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppPreferences.appGroupSuiteName
            ) ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #else
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
        self.directory = directory ?? root.appendingPathComponent("ImportedResultFonts", isDirectory: true)
        style = Self.loadStyle(from: defaults)

        let files = (try? FileManager.default.contentsOfDirectory(
            at: self.directory,
            includingPropertiesForKeys: nil
        )) ?? []
        for file in files where Self.supports(file) {
            if CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil) {
                fonts.append(contentsOf: Self.descriptors(at: file))
            } else {
                let descriptors = Self.descriptors(at: file)
                #if canImport(UIKit)
                    fonts.append(contentsOf: descriptors.filter { UIFont(name: $0.postScriptName, size: 15) != nil })
                #elseif canImport(AppKit)
                    fonts.append(contentsOf: descriptors.filter { NSFont(name: $0.postScriptName, size: 15) != nil })
                #endif
            }
        }
        fonts.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        if let name = style.fontName, !fonts.contains(where: { $0.postScriptName == name }) {
            style.fontName = nil
        }
    }

    func reloadStyleFromDefaults() {
        var loaded = Self.loadStyle(from: defaults)
        if let name = loaded.fontName, !fonts.contains(where: { $0.postScriptName == name }) {
            loaded.fontName = nil
        }
        style = loaded
    }

    private static func loadStyle(from defaults: UserDefaults) -> ResultReadingStyle {
        let saved = defaults.data(forKey: styleKey)
            .flatMap { try? JSONDecoder().decode(ResultReadingStyle.self, from: $0) }
        var loaded = saved ?? ResultReadingStyle()
        loaded.textSize = loaded.textSize.isFinite
            ? min(max(loaded.textSize, textSizeRange.lowerBound), textSizeRange.upperBound)
            : 15
        return loaded
    }

    @discardableResult
    func importFont(from source: URL) throws -> ImportedResultFont {
        guard Self.supports(source) else {
            throw FontImportError.unsupportedFile
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                source.stopAccessingSecurityScopedResource()
            }
        }
        let sourceFonts = Self.descriptors(at: source)
        guard !sourceFonts.isEmpty else {
            throw FontImportError.invalidFont
        }
        if let existing = fonts.first(where: { $0.postScriptName == sourceFonts[0].postScriptName }) {
            style.fontName = existing.postScriptName
            return existing
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(source.pathExtension.lowercased())
        try FileManager.default.copyItem(at: source, to: destination)
        var registrationError: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(destination as CFURL, .process, &registrationError) else {
            try? FileManager.default.removeItem(at: destination)
            if let error = registrationError?.takeRetainedValue() {
                throw error as Error
            }
            throw FontImportError.invalidFont
        }
        let imported = Self.descriptors(at: destination)
        guard let first = imported.first else {
            CTFontManagerUnregisterFontsForURL(destination as CFURL, .process, nil)
            try? FileManager.default.removeItem(at: destination)
            throw FontImportError.invalidFont
        }
        fonts.append(contentsOf: imported)
        fonts.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        style.fontName = first.postScriptName
        return first
    }

    /// Downloads a TTF/OTF file and imports it like a Files import.
    @MainActor
    @discardableResult
    func downloadFont(from remote: URL) async throws -> ImportedResultFont {
        let (temporary, response) = try await URLSession.shared.download(from: remote)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw FontImportError.downloadFailed
        }
        // The download lands with a .tmp name; importFont validates by extension.
        let named = temporary.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(remote.pathExtension.lowercased())
        try FileManager.default.moveItem(at: temporary, to: named)
        defer { try? FileManager.default.removeItem(at: named) }
        return try importFont(from: named)
    }

    func remove(_ font: ImportedResultFont) throws {
        CTFontManagerUnregisterFontsForURL(font.fileURL as CFURL, .process, nil)
        do {
            try FileManager.default.removeItem(at: font.fileURL)
        } catch {
            CTFontManagerRegisterFontsForURL(font.fileURL as CFURL, .process, nil)
            throw error
        }
        if fonts.contains(where: { $0.fileURL == font.fileURL && $0.postScriptName == style.fontName }) {
            style.fontName = nil
        }
        fonts.removeAll { $0.fileURL == font.fileURL }
    }

    private static func supports(_ url: URL) -> Bool {
        ["ttf", "otf"].contains(url.pathExtension.lowercased())
    }

    private static func descriptors(at url: URL) -> [ImportedResultFont] {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] else {
            return []
        }
        return descriptors.compactMap { descriptor in
            guard let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
                return nil
            }
            let displayName = CTFontDescriptorCopyAttribute(descriptor, kCTFontDisplayNameAttribute) as? String ?? name
            return ImportedResultFont(postScriptName: name, displayName: displayName, fileURL: url)
        }
    }
}

private enum FontImportError: LocalizedError {
    case unsupportedFile
    case invalidFont
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            String(localized: "Choose a TTF or OTF font file. Unzip downloaded archives before importing.")
        case .invalidFont:
            String(localized: "This file could not be read as a font.")
        case .downloadFailed:
            String(localized: "The font could not be downloaded. Check your connection and try again.")
        }
    }
}
