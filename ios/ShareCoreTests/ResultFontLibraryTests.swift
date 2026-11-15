import Foundation
@testable import ShareCore
import Testing

@Suite("Result font library")
struct ResultFontLibraryTests {
    @Test("Persists size and restores the system font when the imported file is missing")
    func persistence() throws {
        let suiteName = "ResultFontLibraryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = ResultFontLibrary(defaults: defaults, directory: directory)
        library.style = ResultReadingStyle(fontName: "MissingFont", textSize: 22)

        let restored = ResultFontLibrary(defaults: defaults, directory: directory)
        #expect(restored.style.fontName == nil)
        #expect(restored.style.textSize == 22)
        #expect(restored.fonts.isEmpty)
    }

    @Test("Clamps a saved size outside the supported range")
    func sizeBounds() throws {
        let suiteName = "ResultFontLibraryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try defaults.set(
            JSONEncoder().encode(ResultReadingStyle(textSize: 100)),
            forKey: ResultFontLibrary.styleKey
        )
        let library = ResultFontLibrary(
            defaults: defaults,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        #expect(library.style.textSize == ResultFontLibrary.textSizeRange.upperBound)
    }

    @Test("Rejects invalid font files without changing the selection or copying them")
    func invalidImport() throws {
        let suiteName = "ResultFontLibraryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("invalid.ttf")
        try Data("not a font".utf8).write(to: source)
        let directory = root.appendingPathComponent("imported")
        let library = ResultFontLibrary(defaults: defaults, directory: directory)
        #expect(throws: (any Error).self) {
            try library.importFont(from: source)
        }
        #expect(throws: (any Error).self) {
            try library.importFont(from: root.appendingPathComponent("archive.zip"))
        }
        #expect(library.fonts.isEmpty)
        #expect(library.style == ResultReadingStyle())
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
