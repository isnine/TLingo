//
//  RealtimeHistoryExportDocument.swift
//  ShareCore
//

import AVFoundation
import Foundation
import SwiftUI
import UniformTypeIdentifiers

public struct RealtimeHistoryExportDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.folder] }
    public static var writableContentTypes: [UTType] { [.folder] }

    private let session: RealtimeHistorySession

    public init(session: RealtimeHistorySession) {
        self.session = session
    }

    public init(configuration _: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    public init(fileWrapper _: FileWrapper, contentType _: UTType) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    public func fileWrapper(configuration _: WriteConfiguration) throws -> FileWrapper {
        try makeFileWrapper()
    }

    func makeFileWrapper() throws -> FileWrapper {
        let audioWrappers = try audioDirectoryWrappers()
        var wrappers = [
            "transcript.md": FileWrapper(regularFileWithContents: markdownData()),
            "audio": FileWrapper(directoryWithFileWrappers: audioWrappers),
        ]
        let trackWrappers = trackDirectoryWrappers()
        if !trackWrappers.isEmpty {
            wrappers["tracks"] = FileWrapper(directoryWithFileWrappers: trackWrappers)
        }
        return FileWrapper(directoryWithFileWrappers: wrappers)
    }

    private func audioDirectoryWrappers() throws -> [String: FileWrapper] {
        var wrappers: [String: FileWrapper] = [:]
        for recording in session.audioRecordings.filter(\.hasPlayableAudio) {
            let data = try mergedAudioData(for: recording)
            if !data.isEmpty {
                wrappers[recording.source.exportAudioFilename(format: recording.format)] = FileWrapper(
                    regularFileWithContents: data
                )
                let lrcData = lrcData(for: recording.source)
                if !lrcData.isEmpty {
                    wrappers[recording.source.exportLRCFilename] = FileWrapper(regularFileWithContents: lrcData)
                }
            }
        }
        return wrappers
    }

    private func mergedAudioData(for recording: RealtimeHistoryAudioRecording) throws -> Data {
        let urls = try audioSegmentURLs(for: recording)
        guard let firstURL = urls.first else { return Data() }

        let firstFile = try AVAudioFile(forReading: firstURL)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("TLingo-Realtime-\(UUID().uuidString)")
            .appendingPathExtension(recording.format)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        do {
            let outputFile = try AVAudioFile(forWriting: tempURL, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: firstFile.processingFormat.sampleRate,
                AVNumberOfChannelsKey: Int(firstFile.processingFormat.channelCount),
                AVEncoderBitRateKey: 32000,
            ])
            for url in urls {
                try appendAudio(from: url, to: outputFile)
            }
        }

        return try Data(contentsOf: tempURL)
    }

    private func audioSegmentURLs(for recording: RealtimeHistoryAudioRecording) throws -> [URL] {
        try recording.segments.sorted(by: { $0.offset < $1.offset }).map { segment in
            guard let url = RealtimeHistoryAudioStorage.fileURL(for: segment),
                  FileManager.default.fileExists(atPath: url.path)
            else {
                throw RealtimeHistoryExportError.missingAudioFile(segment.relativePath)
            }
            return url
        }
    }

    private func appendAudio(from url: URL, to outputFile: AVAudioFile) throws {
        let audioFile = try AVAudioFile(forReading: url)
        while audioFile.framePosition < audioFile.length {
            let frameCount = min(Self.audioReadFrameCapacity, AVAudioFrameCount(audioFile.length - audioFile.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try audioFile.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }
            try outputFile.write(from: buffer)
        }
    }

    private func markdownData() -> Data {
        Data(markdown().utf8)
    }

    private func lrcData(for source: RealtimeHistoryAudioSource) -> Data {
        Data(lrcText(for: source).utf8)
    }

    private func lrcText(for source: RealtimeHistoryAudioSource) -> String {
        let blocks = lrcItems(for: source).compactMap { item -> String? in
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let translatedText = item.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || !translatedText.isEmpty else { return nil }
            let firstLine = "[\(Self.lrcTimestamp(for: item.offset))]\(text.isEmpty ? translatedText : text)"
            let lines = translatedText.isEmpty || text.isEmpty ? [firstLine] : [firstLine, translatedText]
            return lines.joined(separator: "\n")
        }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private func lrcItems(for source: RealtimeHistoryAudioSource) -> [RealtimeHistoryConversationItem] {
        let delayedSegments = session.delayedTranscriptSegments.filter { $0.source == source }
        if !delayedSegments.isEmpty {
            return delayedSegments.map { segment in
                RealtimeHistoryConversationItem(
                    id: segment.id,
                    source: segment.source,
                    offset: segment.offset,
                    text: segment.text,
                    translatedText: segment.translatedText
                )
            }
            .sorted { $0.offset < $1.offset }
        }

        let delayedItems = session.delayedConversationItems.filter { $0.source == source }
        if !delayedItems.isEmpty {
            return delayedItems.sorted { $0.offset < $1.offset }
        }

        guard source == primaryAudioSource else { return [] }
        return session.segments.map { segment in
            RealtimeHistoryConversationItem(
                id: segment.id,
                source: source,
                offset: segment.offset,
                text: segment.sourceText,
                translatedText: segment.translatedText
            )
        }
        .sorted { $0.offset < $1.offset }
    }

    private var primaryAudioSource: RealtimeHistoryAudioSource {
        session.primaryAudioSource
    }

    private func markdown() -> String {
        bilingualTranscriptLines().joined(separator: "\n") + "\n"
    }

    private func bilingualTranscriptLines() -> [String] {
        if !session.tracks.isEmpty {
            return session.tracks.flatMap { track in
                let source = (track.audioSource ?? session.primaryAudioSource).title
                var lines = ["## \(source) · \(track.title)", ""]
                for segment in track.segments.sorted(by: { $0.offset < $1.offset }) {
                    let time = "\(segment.offsetLabel)-\(segment.endOffset.clockLabel)"
                    let speaker = segment.speakerID.map { " · Speaker \($0)" } ?? ""
                    lines.append("### \(time)\(speaker)")
                    lines.append("")
                    if !segment.sourceText.isEmpty {
                        lines.append(segment.sourceText)
                        lines.append("")
                    }
                    if !segment.translatedText.isEmpty {
                        lines.append(segment.translatedText)
                        lines.append("")
                    }
                }
                return lines
            }
        }

        var lines: [String] = []

        for segment in session.segments.sorted(by: { $0.offset < $1.offset }) {
            lines.append("### \(segment.offsetLabel)")
            lines.append("")
            lines.append(segment.sourceText)
            lines.append("")
            lines.append(segment.translatedText)
            lines.append("")
        }
        return lines
    }

    private func trackDirectoryWrappers() -> [String: FileWrapper] {
        Dictionary(uniqueKeysWithValues: session.tracks.enumerated().compactMap { index, track in
            let text = trackLRCText(track)
            guard !text.isEmpty else { return nil }
            let filename = String(
                format: "%02d-%@.lrc",
                index + 1,
                Self.filenameSlug(track.title)
            )
            return (filename, FileWrapper(regularFileWithContents: Data(text.utf8)))
        })
    }

    private func trackLRCText(_ track: RealtimeHistoryTrack) -> String {
        let blocks = track.segments.sorted(by: { $0.offset < $1.offset }).compactMap { segment -> String? in
            let source = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty || !translation.isEmpty else { return nil }
            let timestamp = "[\(Self.lrcTimestamp(for: segment.offset))]"
            let speaker = segment.speakerID.map { "[Speaker \($0)] " } ?? ""
            switch segment.relation {
            case .paired:
                return [timestamp + speaker + source, translation].filter { !$0.isEmpty }.joined(separator: "\n")
            case .sourceOnly:
                return timestamp + speaker + source
            case .translationOnly:
                return timestamp + speaker + translation
            }
        }
        guard !blocks.isEmpty else { return "" }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func filenameSlug(_ input: String) -> String {
        let allowed = input.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed)
            .split(separator: "-")
            .joined(separator: "-")
            .prefix(80)
            .description
    }

    private static let audioReadFrameCapacity: AVAudioFrameCount = 4096

    private static func lrcTimestamp(for offset: TimeInterval) -> String {
        let totalMilliseconds = max(0, Int((offset * 1000).rounded()))
        let minutes = totalMilliseconds / 60000
        let seconds = (totalMilliseconds / 1000) % 60
        let milliseconds = totalMilliseconds % 1000
        return String(format: "%02d:%02d.%03d", minutes, seconds, milliseconds)
    }
}

enum RealtimeHistoryExportError: LocalizedError, Equatable {
    case missingAudioFile(String)

    var errorDescription: String? {
        switch self {
        case let .missingAudioFile(path):
            return String(localized: "Missing audio file: \(path)")
        }
    }
}

private extension RealtimeHistoryAudioSource {
    var exportBaseFilename: String {
        switch self {
        case .importedAudio:
            return "imported-audio"
        case .macAudio:
            return "mac-audio"
        case .microphone:
            return "microphone"
        }
    }

    func exportAudioFilename(format: String) -> String {
        "\(exportBaseFilename).\(format)"
    }

    var exportLRCFilename: String {
        "\(exportBaseFilename).lrc"
    }
}
