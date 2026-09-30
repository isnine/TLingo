//
//  TranslationRecord.swift
//  ShareCore
//
//  Created by Zander Wang on 2026/03/13.
//

import Foundation
import SwiftData

public extension TimeInterval {
    var clockLabel: String {
        let totalSeconds = max(0, Int(rounded()))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}

public struct RealtimeHistorySegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var offset: TimeInterval
    public var sourceText: String
    public var translatedText: String

    public init(
        id: UUID = UUID(),
        offset: TimeInterval,
        sourceText: String,
        translatedText: String
    ) {
        self.id = id
        self.offset = offset
        self.sourceText = sourceText
        self.translatedText = translatedText
    }

    public var offsetLabel: String {
        offset.clockLabel
    }
}

public struct RealtimeHistoryAudioSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var relativePath: String
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var byteCount: Int64

    public init(
        id: UUID = UUID(),
        relativePath: String,
        offset: TimeInterval,
        duration: TimeInterval,
        byteCount: Int64
    ) {
        self.id = id
        self.relativePath = relativePath
        self.offset = offset
        self.duration = duration
        self.byteCount = byteCount
    }
}

public enum RealtimeHistoryAudioSource: String, Codable, Hashable, Sendable {
    case importedAudio
    case macAudio
    case microphone

    public var title: String {
        switch self {
        case .importedAudio:
            return String(localized: "Imported Audio")
        case .macAudio:
            return String(localized: "Mac Audio")
        case .microphone:
            return String(localized: "Microphone")
        }
    }

    public var systemImage: String {
        switch self {
        case .importedAudio:
            return "waveform.badge.plus"
        case .macAudio:
            return "speaker.wave.2.fill"
        case .microphone:
            return "mic.fill"
        }
    }
}

public enum RealtimeHistoryInputSource: String, Codable, Hashable, Sendable {
    case importedAudio
    case macAudio
    case microphone
    case iphoneAudio
}

public struct RealtimeHistoryAudioRecording: Codable, Hashable, Sendable {
    public var id: UUID
    public var source: RealtimeHistoryAudioSource
    public var directoryName: String
    public var format: String
    public var sampleRate: Double
    public var channelCount: Int
    public var segments: [RealtimeHistoryAudioSegment]

    public init(
        id: UUID = UUID(),
        source: RealtimeHistoryAudioSource = .microphone,
        directoryName: String,
        format: String = "m4a",
        sampleRate: Double,
        channelCount: Int,
        segments: [RealtimeHistoryAudioSegment]
    ) {
        self.id = id
        self.source = source
        self.directoryName = directoryName
        self.format = format
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.segments = segments
    }

    public var duration: TimeInterval {
        segments.reduce(0) { $0 + $1.duration }
    }

    public var hasPlayableAudio: Bool {
        !segments.isEmpty
    }

    public var durationLabel: String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case directoryName
        case format
        case sampleRate
        case channelCount
        case segments
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        source = (try? container.decode(RealtimeHistoryAudioSource.self, forKey: .source)) ?? .microphone
        directoryName = try container.decode(String.self, forKey: .directoryName)
        format = (try? container.decode(String.self, forKey: .format)) ?? "m4a"
        sampleRate = try container.decode(Double.self, forKey: .sampleRate)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        segments = try container.decode([RealtimeHistoryAudioSegment].self, forKey: .segments)
    }
}

public struct RealtimeHistoryTranscriptSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var source: RealtimeHistoryAudioSource
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var text: String
    public var translatedText: String

    public init(
        id: UUID = UUID(),
        source: RealtimeHistoryAudioSource,
        offset: TimeInterval,
        duration: TimeInterval,
        text: String,
        translatedText: String = ""
    ) {
        self.id = id
        self.source = source
        self.offset = offset
        self.duration = duration
        self.text = text
        self.translatedText = translatedText
    }
}

public struct RealtimeHistoryConversationItem: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var source: RealtimeHistoryAudioSource
    public var offset: TimeInterval
    public var text: String
    public var translatedText: String

    public init(
        id: UUID = UUID(),
        source: RealtimeHistoryAudioSource,
        offset: TimeInterval,
        text: String,
        translatedText: String = ""
    ) {
        self.id = id
        self.source = source
        self.offset = offset
        self.text = text
        self.translatedText = translatedText
    }
}

public struct RealtimeHistoryTranscriptionModel: Codable, Hashable, Sendable {
    public var source: RealtimeHistoryAudioSource
    public var modelID: String
    public var modelDisplayName: String

    public init(source: RealtimeHistoryAudioSource, modelID: String, modelDisplayName: String) {
        self.source = source
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
    }
}

public enum RealtimeHistoryTrackSegmentRelation: String, Codable, Hashable, Sendable {
    case paired
    case sourceOnly
    case translationOnly
}

public struct RealtimeHistoryTrackSegment: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var speakerID: String?
    public var sourceText: String
    public var translatedText: String
    public var relation: RealtimeHistoryTrackSegmentRelation

    public init(
        id: UUID = UUID(),
        offset: TimeInterval,
        duration: TimeInterval = 0.5,
        speakerID: String? = nil,
        sourceText: String = "",
        translatedText: String = "",
        relation: RealtimeHistoryTrackSegmentRelation
    ) {
        self.id = id
        self.offset = offset
        self.duration = duration
        self.speakerID = speakerID
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.relation = relation
    }

    public var offsetLabel: String {
        offset.clockLabel
    }

    public var endOffset: TimeInterval {
        offset + duration
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case offset
        case duration
        case speakerID
        case sourceText
        case translatedText
        case relation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        offset = try container.decode(TimeInterval.self, forKey: .offset)
        duration = (try? container.decode(TimeInterval.self, forKey: .duration)) ?? 0.5
        speakerID = try? container.decode(String.self, forKey: .speakerID)
        sourceText = try container.decode(String.self, forKey: .sourceText)
        translatedText = try container.decode(String.self, forKey: .translatedText)
        relation = try container.decode(RealtimeHistoryTrackSegmentRelation.self, forKey: .relation)
    }
}

public struct RealtimeHistoryTrack: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var audioSource: RealtimeHistoryAudioSource?
    public var startedOffset: TimeInterval
    public var endedOffset: TimeInterval?
    public var recognitionModelID: String
    public var recognitionModelDisplayName: String
    public var translationProviderID: String
    public var translationProviderDisplayName: String
    public var segments: [RealtimeHistoryTrackSegment]
    public var updatedAt: Date?

    public init(
        id: UUID = UUID(),
        audioSource: RealtimeHistoryAudioSource? = nil,
        startedOffset: TimeInterval = 0,
        endedOffset: TimeInterval? = nil,
        recognitionModelID: String,
        recognitionModelDisplayName: String,
        translationProviderID: String,
        translationProviderDisplayName: String,
        segments: [RealtimeHistoryTrackSegment] = [],
        updatedAt: Date? = nil
    ) {
        self.id = id
        self.audioSource = audioSource
        self.startedOffset = startedOffset
        self.endedOffset = endedOffset
        self.recognitionModelID = recognitionModelID
        self.recognitionModelDisplayName = recognitionModelDisplayName
        self.translationProviderID = translationProviderID
        self.translationProviderDisplayName = translationProviderDisplayName
        self.segments = segments
        self.updatedAt = updatedAt
    }

    public var title: String {
        "\(recognitionModelDisplayName) → \(translationProviderDisplayName)"
    }

    public func conversationSpeakerID(for speakerID: String) -> String {
        guard recognitionModelID == RecognitionModelDescriptor.mossTranscribeDiarize.id,
              let separator = speakerID.firstIndex(of: "-")
        else {
            return speakerID
        }
        let partID = speakerID[..<separator]
        let localID = speakerID[speakerID.index(after: separator)...]
        guard partID.first == "P",
              partID.dropFirst().allSatisfy(\.isNumber),
              localID.first == "S",
              localID.dropFirst().allSatisfy(\.isNumber)
        else {
            return speakerID
        }
        return String(localID)
    }

    public var dominantConversationSpeakerIDs: [String]? {
        var durationBySpeaker: [String: TimeInterval] = [:]
        for segment in segments {
            guard let speakerID = segment.speakerID else { continue }
            let groupedSpeakerID = conversationSpeakerID(for: speakerID)
            durationBySpeaker[groupedSpeakerID, default: 0] += max(segment.duration, 0)
        }
        let durations = durationBySpeaker.sorted {
            $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value
        }
        guard durations.count >= 2 else { return nil }
        let total = durations.reduce(0) { $0 + $1.value }
        guard total > 0, (durations[0].value + durations[1].value) / total > 0.5 else {
            return nil
        }
        return [durations[0].key, durations[1].key]
    }

    /// Always exactly one active segment (nil only for an empty track): the latest segment that has
    /// started, or the first one before playback reaches it, so gaps and overlaps never leave
    /// zero or two highlights.
    public func activeSegmentID(at time: TimeInterval) -> UUID? {
        let ordered = segments.enumerated().sorted {
            $0.element.offset == $1.element.offset ? $0.offset < $1.offset : $0.element.offset < $1.element.offset
        }
        return (ordered.last { $0.element.offset <= time } ?? ordered.first)?.element.id
    }

    public func closestSegmentID(to time: TimeInterval) -> UUID? {
        segments.min {
            $0.distance(to: time) < $1.distance(to: time)
        }?.id
    }

    public var legacySegments: [RealtimeHistorySegment] {
        segments.compactMap { segment in
            let source = segment.sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let translation = segment.translatedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !source.isEmpty || !translation.isEmpty else { return nil }
            let legacySource = source.isEmpty ? translation : source
            let legacyTranslation = translation.isEmpty ? legacySource : translation
            return RealtimeHistorySegment(
                id: segment.id,
                offset: segment.offset,
                sourceText: legacySource,
                translatedText: legacyTranslation
            )
        }
    }
}

private extension RealtimeHistoryTrackSegment {
    func distance(to time: TimeInterval) -> TimeInterval {
        if time < offset {
            return offset - time
        }
        if time > endOffset {
            return time - endOffset
        }
        return 0
    }
}

public struct RealtimeHistorySession: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var generatedTitle: String?
    public var startedAt: Date
    public var endedAt: Date
    public var duration: TimeInterval
    public var inputSource: String
    public var inputSourceID: RealtimeHistoryInputSource?
    public var sourceLanguage: String
    public var targetLanguage: String
    public var modelID: String
    public var modelDisplayName: String
    public var segments: [RealtimeHistorySegment]
    public var audioRecordings: [RealtimeHistoryAudioRecording]
    public var delayedTranscriptSegments: [RealtimeHistoryTranscriptSegment]
    public var delayedConversationItems: [RealtimeHistoryConversationItem]
    public var transcriptionModels: [RealtimeHistoryTranscriptionModel]
    public var tracks: [RealtimeHistoryTrack]
    public var primaryTrackID: UUID?
    public var speakerNames: [String: String]

    public var audioRecording: RealtimeHistoryAudioRecording? {
        get { audioRecordings.first }
        set { audioRecordings = newValue.map { [$0] } ?? [] }
    }

    public var primaryAudioSource: RealtimeHistoryAudioSource {
        if let source = audioRecordings.first(where: { !$0.segments.isEmpty })?.source {
            return source
        }
        if inputSourceID == .macAudio {
            return .macAudio
        }
        return inputSource == RealtimeHistoryAudioSource.macAudio.title ? .macAudio : .microphone
    }

    public init(
        requestID: UUID,
        generatedTitle: String? = nil,
        startedAt: Date,
        endedAt: Date,
        duration: TimeInterval,
        inputSource: String,
        inputSourceID: RealtimeHistoryInputSource? = nil,
        sourceLanguage: String,
        targetLanguage: String,
        modelID: String,
        modelDisplayName: String,
        segments: [RealtimeHistorySegment],
        audioRecording: RealtimeHistoryAudioRecording? = nil,
        audioRecordings: [RealtimeHistoryAudioRecording] = [],
        delayedTranscriptSegments: [RealtimeHistoryTranscriptSegment] = [],
        delayedConversationItems: [RealtimeHistoryConversationItem] = [],
        transcriptionModels: [RealtimeHistoryTranscriptionModel] = [],
        tracks: [RealtimeHistoryTrack] = [],
        primaryTrackID: UUID? = nil,
        speakerNames: [String: String] = [:]
    ) {
        self.requestID = requestID
        self.generatedTitle = generatedTitle
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.duration = duration
        self.inputSource = inputSource
        self.inputSourceID = inputSourceID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.segments = segments
        self.audioRecordings = audioRecordings
        if let audioRecording, self.audioRecordings.isEmpty {
            self.audioRecordings = [audioRecording]
        }
        self.delayedTranscriptSegments = delayedTranscriptSegments
        self.delayedConversationItems = delayedConversationItems
        self.transcriptionModels = transcriptionModels
        self.speakerNames = speakerNames
        if tracks.isEmpty, !segments.isEmpty {
            let recognitionModel = transcriptionModels.first
            let legacyAudioSource = self.audioRecordings.first(where: { !$0.segments.isEmpty })?.source ??
                (
                    inputSourceID == .macAudio || inputSource == RealtimeHistoryAudioSource.macAudio.title
                        ? .macAudio
                        : .microphone
                )
            // A stable ID keeps every autosave of this session merging into one track.
            let legacyTrack = RealtimeHistoryTrack(
                id: requestID,
                audioSource: legacyAudioSource,
                recognitionModelID: recognitionModel?.modelID ?? RecognitionModelDescriptor.appleSpeech.id,
                recognitionModelDisplayName: recognitionModel?.modelDisplayName ??
                    RecognitionModelDescriptor.appleSpeech.title,
                translationProviderID: modelID,
                translationProviderDisplayName: modelDisplayName,
                segments: segments.map {
                    RealtimeHistoryTrackSegment(
                        id: $0.id,
                        offset: $0.offset,
                        sourceText: $0.sourceText,
                        translatedText: $0.translatedText,
                        relation: .paired
                    )
                }
            )
            self.tracks = [legacyTrack]
            self.primaryTrackID = legacyTrack.id
        } else {
            self.tracks = tracks
            self.primaryTrackID = primaryTrackID ?? tracks.first?.id
        }
    }

    private enum CodingKeys: String, CodingKey {
        case requestID
        case generatedTitle
        case startedAt
        case endedAt
        case duration
        case inputSource
        case inputSourceID
        case sourceLanguage
        case targetLanguage
        case modelID
        case modelDisplayName
        case segments
        case audioRecording
        case audioRecordings
        case delayedTranscriptSegments
        case delayedConversationItems
        case transcriptionModels
        case tracks
        case primaryTrackID
        case speakerNames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(UUID.self, forKey: .requestID)
        generatedTitle = try? container.decode(String.self, forKey: .generatedTitle)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        inputSource = try container.decode(String.self, forKey: .inputSource)
        inputSourceID = try? container.decode(RealtimeHistoryInputSource.self, forKey: .inputSourceID)
        sourceLanguage = try container.decode(String.self, forKey: .sourceLanguage)
        targetLanguage = try container.decode(String.self, forKey: .targetLanguage)
        modelID = try container.decode(String.self, forKey: .modelID)
        modelDisplayName = try container.decode(String.self, forKey: .modelDisplayName)
        segments = try container.decode([RealtimeHistorySegment].self, forKey: .segments)
        let decodedRecordings = (try? container.decode([RealtimeHistoryAudioRecording].self, forKey: .audioRecordings)) ?? []
        if decodedRecordings.isEmpty,
           var legacyRecording = try? container.decode(RealtimeHistoryAudioRecording.self, forKey: .audioRecording)
        {
            if inputSourceID == .macAudio || inputSource == RealtimeHistoryAudioSource.macAudio.title {
                legacyRecording.source = .macAudio
            }
            audioRecordings = [legacyRecording]
        } else {
            audioRecordings = decodedRecordings
        }
        delayedTranscriptSegments = (try? container.decode(
            [RealtimeHistoryTranscriptSegment].self,
            forKey: .delayedTranscriptSegments
        )) ?? []
        delayedConversationItems = (try? container.decode(
            [RealtimeHistoryConversationItem].self,
            forKey: .delayedConversationItems
        )) ?? []
        transcriptionModels = (try? container.decode(
            [RealtimeHistoryTranscriptionModel].self,
            forKey: .transcriptionModels
        )) ?? []
        tracks = (try? container.decode([RealtimeHistoryTrack].self, forKey: .tracks)) ?? []
        primaryTrackID = try? container.decode(UUID.self, forKey: .primaryTrackID)
        speakerNames = (try? container.decode([String: String].self, forKey: .speakerNames)) ?? [:]
        if tracks.isEmpty {
            let recognitionModel = transcriptionModels.first
            let legacyTrack = RealtimeHistoryTrack(
                id: requestID,
                audioSource: primaryAudioSource,
                recognitionModelID: recognitionModel?.modelID ?? RecognitionModelDescriptor.appleSpeech.id,
                recognitionModelDisplayName: recognitionModel?.modelDisplayName ??
                    RecognitionModelDescriptor.appleSpeech.title,
                translationProviderID: modelID,
                translationProviderDisplayName: modelDisplayName,
                segments: segments.map {
                    RealtimeHistoryTrackSegment(
                        id: $0.id,
                        offset: $0.offset,
                        sourceText: $0.sourceText,
                        translatedText: $0.translatedText,
                        relation: .paired
                    )
                }
            )
            tracks = [legacyTrack]
            primaryTrackID = legacyTrack.id
        } else if primaryTrackID == nil || !tracks.contains(where: { $0.id == primaryTrackID }) {
            primaryTrackID = tracks.first?.id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(requestID, forKey: .requestID)
        try container.encodeIfPresent(generatedTitle, forKey: .generatedTitle)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(endedAt, forKey: .endedAt)
        try container.encode(duration, forKey: .duration)
        try container.encode(inputSource, forKey: .inputSource)
        try container.encodeIfPresent(inputSourceID, forKey: .inputSourceID)
        try container.encode(sourceLanguage, forKey: .sourceLanguage)
        try container.encode(targetLanguage, forKey: .targetLanguage)
        try container.encode(modelID, forKey: .modelID)
        try container.encode(modelDisplayName, forKey: .modelDisplayName)
        try container.encode(segments, forKey: .segments)
        try container.encode(audioRecordings, forKey: .audioRecordings)
        try container.encode(delayedTranscriptSegments, forKey: .delayedTranscriptSegments)
        try container.encode(delayedConversationItems, forKey: .delayedConversationItems)
        try container.encode(transcriptionModels, forKey: .transcriptionModels)
        try container.encode(tracks, forKey: .tracks)
        try container.encodeIfPresent(primaryTrackID, forKey: .primaryTrackID)
        try container.encode(speakerNames, forKey: .speakerNames)
    }

    public var primaryTrack: RealtimeHistoryTrack? {
        if let primaryTrackID, let track = tracks.first(where: { $0.id == primaryTrackID }) {
            return track
        }
        return tracks.first
    }

    public func transcriptionModel(for source: RealtimeHistoryAudioSource) -> RealtimeHistoryTranscriptionModel? {
        transcriptionModels.first { $0.source == source && !$0.modelDisplayName.isEmpty }
    }

    public var sourceText: String {
        segments.map(\.sourceText).joined(separator: "\n")
    }

    public var translatedText: String {
        segments.map(\.translatedText).joined(separator: "\n")
    }

    public var sourceTextForCopy: String {
        copyItems.map { $0.prefixedCopyText($0.text) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public func sourceTextForCopy(source: RealtimeHistoryAudioSource) -> String {
        copyItems(source: source).map { $0.prefixedCopyText($0.text) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public var translatedTextForCopy: String {
        copyItems.map { $0.prefixedCopyText($0.translatedText) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public func translatedTextForCopy(source: RealtimeHistoryAudioSource) -> String {
        copyItems(source: source).map { $0.prefixedCopyText($0.translatedText) }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public var bilingualTextForCopy: String {
        copyItems.map { item in
            [
                item.prefixedCopyText(item.text),
                item.prefixedCopyText(item.translatedText),
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    public func bilingualTextForCopy(source: RealtimeHistoryAudioSource) -> String {
        copyItems(source: source).map { item in
            [
                item.prefixedCopyText(item.text),
                item.prefixedCopyText(item.translatedText),
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private var copyItems: [RealtimeHistoryConversationItem] {
        delayedConversationItems.isEmpty
            ? RealtimeHistoryConversationBuilder.build(from: self)
            : delayedConversationItems
    }

    private func copyItems(source: RealtimeHistoryAudioSource) -> [RealtimeHistoryConversationItem] {
        RealtimeHistoryConversationBuilder.build(from: self, source: source)
    }

    public var historyConversationContext: String {
        var sections = [
            "Action: \(TranslationRecord.realtimeActionName)",
            "Started: \(startedAt.formatted(date: .abbreviated, time: .shortened))",
            "Duration: \(clockDurationLabel)",
            "Input Source: \(inputSource)",
            "Languages: \(languageDirection)",
        ]

        if !modelDisplayName.isEmpty {
            sections.append("Model: \(modelDisplayName)")
        }

        if !tracks.isEmpty {
            sections.append(realtimeTracksConversationContext)
        } else {
            let transcriptItems = copyItems
            if !transcriptItems.isEmpty {
                sections.append(
                    "Transcript Cells:\n" + transcriptItems.map { item in
                        """
                        Cell ID: \(item.id.uuidString)
                        Time: \(item.offset.clockLabel)
                        Source: \(item.source.title)
                        Original:
                        \(item.text)
                        Translation:
                        \(item.translatedText)
                        """
                    }.joined(separator: "\n\n")
                )
            }
        }

        return sections.joined(separator: "\n\n")
    }

    public func displayTitle(fallback: String) -> String {
        let generated = generatedTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !generated.isEmpty {
            return generated
        }
        let first = segments.first?.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return first.isEmpty ? fallback : first
    }

    public var languageDirection: String {
        "\(sourceLanguage) → \(targetLanguage)"
    }

    public var durationLabel: String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return Duration.seconds(totalSeconds).formatted(
            .units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1)
        )
    }

    public var clockDurationLabel: String {
        let totalSeconds = max(0, Int(duration.rounded()))
        return String(format: "%d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    public var metaLine: String {
        "\(Self.relativeTimestamp(startedAt)) · \(durationLabel) · \(languageDirection)"
    }

    private static func relativeTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter.string(from: date)
    }
}

private extension RealtimeHistorySession {
    var realtimeTracksConversationContext: String {
        "Realtime Tracks:\n" + tracks.map { track in
            let cells = track.segments.map { segment in
                let speaker = segment.speakerID.map { "\nSpeaker: \($0)" } ?? ""
                return """
                Cell ID: \(segment.id.uuidString)
                Time: \(segment.offsetLabel)-\(segment.endOffset.clockLabel)\(speaker)
                Original:
                \(segment.sourceText)
                Translation:
                \(segment.translatedText)
                """
            }
            .joined(separator: "\n\n")
            return """
            Track ID: \(track.id.uuidString)
            Audio Source: \((track.audioSource ?? primaryAudioSource).title)
            Recognition: \(track.recognitionModelDisplayName)
            Translation: \(track.translationProviderDisplayName)
            \(cells)
            """
        }.joined(separator: "\n\n")
    }
}

private extension RealtimeHistoryConversationItem {
    func prefixedCopyText(_ text: String) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { "[\(offset.clockLabel)] \(source.title): \($0)" }
        return lines.joined(separator: "\n")
    }
}

public extension TranslationRecord {
    var historyConversationContext: String {
        if let realtimeSession {
            return [
                "History Record ID: \(id.uuidString)",
                realtimeSession.historyConversationContext,
            ].joined(separator: "\n\n")
        }

        var sections: [String] = [
            "History Record ID: \(id.uuidString)",
            "Action: \(actionName.isEmpty ? "Unknown" : actionName)",
            "Timestamp: \(timestamp.formatted(date: .abbreviated, time: .shortened))",
            "Source:\n\(sourceText)",
        ]

        for result in modelResults {
            let modelName = result.modelDisplayName.isEmpty ? result.modelID : result.modelDisplayName
            sections.append(
                """
                Result (\(modelName)):
                \(result.resultText)
                """
            )
        }

        return sections.joined(separator: "\n\n")
    }
}

/// A single model's result within a translation request.
public struct ModelResult: Codable, Identifiable, Hashable {
    public var id: UUID
    public var modelID: String
    public var modelDisplayName: String
    public var resultText: String
    public var duration: TimeInterval

    public init(
        id: UUID = UUID(),
        modelID: String,
        modelDisplayName: String,
        resultText: String,
        duration: TimeInterval
    ) {
        self.id = id
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.resultText = resultText
        self.duration = duration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        modelID = try container.decode(String.self, forKey: .modelID)
        modelDisplayName = try container.decode(String.self, forKey: .modelDisplayName)
        resultText = try container.decode(String.self, forKey: .resultText)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
    }
}

private struct StoredConversationMessage: Codable {
    // ponytail: text-only history; persist image attachments if chat history must restore media.
    let id: UUID
    let role: String
    let content: String
    let reasoning: String?
    let timestamp: Date

    init(_ message: ChatMessage) {
        id = message.id
        role = message.role
        content = message.content
        reasoning = message.reasoning
        timestamp = message.timestamp
    }

    var chatMessage: ChatMessage {
        ChatMessage(
            id: id,
            role: role,
            content: content,
            reasoning: reasoning,
            timestamp: timestamp
        )
    }
}

@Model
public final class TranslationRecord {
    public static let realtimeActionName = "Realtime"
    public static let realtimeSystemImageName = "waveform.and.mic"

    /// Resolves the SF Symbol for a history row's action name, including the
    /// built-in Realtime pseudo-action that isn't part of `AppConfigurationStore.actions`.
    @MainActor
    public static func systemImage(forActionNamed name: String, fallback: String = "bolt.fill") -> String {
        if name == realtimeActionName { return realtimeSystemImageName }
        return AppConfigurationStore.shared.actions
            .first(where: { $0.name == name })?
            .outputType.systemImageName ?? fallback
    }

    public var id: UUID
    public var requestID: UUID
    public var sourceText: String
    public var actionName: String
    public var targetLanguage: String
    public var timestamp: Date
    public var isConversation: Bool

    /// JSON-encoded `[ModelResult]`. SwiftData doesn't natively support arrays of
    /// Codable structs, so we store them as raw Data and expose a computed accessor.
    public var modelResultsData: Data

    /// JSON-encoded `RealtimeHistorySession` for realtime records. Stored at the
    /// record level (mirroring `modelResultsData`) rather than smuggled inside a `ModelResult`.
    public var realtimeSessionData: Data?
    public var historyAnnotationsData: Data?
    public var conversationMessagesData: Data?

    public var modelResults: [ModelResult] {
        get {
            (try? JSONDecoder().decode([ModelResult].self, from: modelResultsData)) ?? []
        }
        set {
            modelResultsData = (try? JSONEncoder().encode(newValue)) ?? Data()
        }
    }

    public var realtimeSession: RealtimeHistorySession? {
        get {
            realtimeSessionData.flatMap { try? JSONDecoder().decode(RealtimeHistorySession.self, from: $0) }
        }
        set {
            realtimeSessionData = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    public var conversationMessages: [ChatMessage] {
        get {
            guard let conversationMessagesData,
                  let stored = try? JSONDecoder().decode([StoredConversationMessage].self, from: conversationMessagesData)
            else {
                return []
            }
            return stored.map(\.chatMessage)
        }
        set {
            conversationMessagesData = newValue.isEmpty
                ? nil
                : try? JSONEncoder().encode(newValue.map(StoredConversationMessage.init))
        }
    }

    public var historyAnnotations: [String: String] {
        get {
            guard let historyAnnotationsData else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: historyAnnotationsData)) ?? [:]
        }
        set {
            historyAnnotationsData = newValue.isEmpty ? nil : try? JSONEncoder().encode(newValue)
        }
    }

    public func annotation(for targetID: UUID) -> String? {
        let trimmed = historyAnnotations[targetID.uuidString]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public var annotationTargetIDs: Set<UUID> {
        guard let realtimeSession else { return [id] }
        let trackTargetIDs = realtimeSession.tracks.flatMap { track in
            track.segments.map(\.id)
        }
        let items = realtimeSession.delayedConversationItems.isEmpty
            ? RealtimeHistoryConversationBuilder.build(from: realtimeSession)
            : realtimeSession.delayedConversationItems
        return Set(trackTargetIDs + items.map(\.id))
    }

    public var isRealtimeRecord: Bool {
        realtimeSessionData != nil || actionName == Self.realtimeActionName
    }

    public init(
        id: UUID = UUID(),
        requestID: UUID = UUID(),
        sourceText: String,
        actionName: String = "",
        targetLanguage: String = "",
        timestamp: Date = Date(),
        isConversation: Bool = false,
        modelResults: [ModelResult] = [],
        conversationMessages: [ChatMessage] = []
    ) {
        self.id = id
        self.requestID = requestID
        self.sourceText = sourceText
        self.actionName = actionName
        self.targetLanguage = targetLanguage
        self.timestamp = timestamp
        self.isConversation = isConversation
        modelResultsData = (try? JSONEncoder().encode(modelResults)) ?? Data()
        realtimeSessionData = nil
        historyAnnotationsData = nil
        conversationMessagesData = conversationMessages.isEmpty
            ? nil
            : try? JSONEncoder().encode(conversationMessages.map(StoredConversationMessage.init))
    }
}
