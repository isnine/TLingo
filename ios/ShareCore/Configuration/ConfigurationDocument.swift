//
//  ConfigurationDocument.swift
//  ShareCore
//
//  Created by AI Assistant on 2025/12/31.
//

import SwiftUI
import UniformTypeIdentifiers

/// A document type for importing/exporting configuration as JSON
public struct ConfigurationDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.json] }
    public static var writableContentTypes: [UTType] { [.json] }

    public var configuration: AppConfiguration

    public init(configuration: AppConfiguration = AppConfiguration()) {
        self.configuration = configuration
    }

    public init(configuration: inout AppConfiguration) {
        self.configuration = configuration
    }

    public init(jsonString: String) throws {
        guard let data = jsonString.data(using: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let decoder = JSONDecoder()
        configuration = try decoder.decode(AppConfiguration.self, from: data)
    }

    public init(data: Data) throws {
        let decoder = JSONDecoder()
        configuration = try decoder.decode(AppConfiguration.self, from: data)
    }

    public init(fileWrapper: FileWrapper, contentType _: UTType) throws {
        guard let data = fileWrapper.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: data)
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: data)
    }

    public func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(configuration)
        return FileWrapper(regularFileWithContents: data)
    }

    public var jsonString: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
