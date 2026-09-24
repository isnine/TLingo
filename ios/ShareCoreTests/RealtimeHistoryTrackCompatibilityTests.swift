import Foundation
import Testing

@testable import ShareCore

@Suite("Realtime history track compatibility")
struct RealtimeHistoryTrackCompatibilityTests {
    @Test("Decodes legacy track fields with compatible defaults")
    func decodesLegacyTrackFields() throws {
        let data = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000021",
          "startedOffset": 0,
          "recognitionModelID": "apple-speech",
          "recognitionModelDisplayName": "Apple Speech",
          "translationProviderID": "apple-translate",
          "translationProviderDisplayName": "Apple Translate",
          "segments": [
            {
              "id": "00000000-0000-0000-0000-000000000022",
              "offset": 3,
              "sourceText": "Hello",
              "translatedText": "Hola",
              "relation": "paired"
            }
          ]
        }
        """.utf8)

        let track = try JSONDecoder().decode(RealtimeHistoryTrack.self, from: data)

        #expect(track.audioSource == nil)
        #expect(track.segments.first?.duration == 0.5)
        #expect(track.segments.first?.speakerID == nil)
    }

    @Test("Round trips imported audio source")
    func roundTripsImportedAudioSource() throws {
        let track = RealtimeHistoryTrack(
            audioSource: .importedAudio,
            recognitionModelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
            recognitionModelDisplayName: RecognitionModelDescriptor.mossTranscribeDiarize.title,
            translationProviderID: RealtimeTranslationProvider.transcriptionOnly.rawValue,
            translationProviderDisplayName: RealtimeTranslationProvider.transcriptionOnly.title
        )

        let decoded = try JSONDecoder().decode(
            RealtimeHistoryTrack.self,
            from: JSONEncoder().encode(track)
        )

        #expect(decoded.audioSource == .importedAudio)
    }

    @Test("Uses conversation layout when two speakers cover more than half")
    func dominantConversationSpeakers() {
        let track = RealtimeHistoryTrack(
            recognitionModelID: "moss",
            recognitionModelDisplayName: "MOSS",
            translationProviderID: "apple",
            translationProviderDisplayName: "Apple",
            segments: [
                segment(speaker: "S01", duration: 5),
                segment(speaker: "S02", duration: 3),
                segment(speaker: "S03", duration: 2),
            ]
        )

        #expect(track.dominantConversationSpeakerIDs == ["S01", "S02"])
    }

    @Test("Merges chunk-scoped MOSS speaker IDs for conversation layout")
    func groupsChunkScopedMOSSConversationSpeakers() {
        let track = RealtimeHistoryTrack(
            recognitionModelID: RecognitionModelDescriptor.mossTranscribeDiarize.id,
            recognitionModelDisplayName: "MOSS",
            translationProviderID: "apple",
            translationProviderDisplayName: "Apple",
            segments: [
                segment(speaker: "P1-S01", duration: 3),
                segment(speaker: "P2-S01", duration: 2),
                segment(speaker: "P1-S02", duration: 2),
                segment(speaker: "P2-S02", duration: 2),
                segment(speaker: "P1-S03", duration: 3),
            ]
        )

        #expect(track.dominantConversationSpeakerIDs == ["S01", "S02"])
        #expect(track.conversationSpeakerID(for: "P2-S01") == "S01")
    }

    @Test("Keeps leading layout when two speakers cover half or less")
    func noDominantConversationSpeakers() {
        let track = RealtimeHistoryTrack(
            recognitionModelID: "moss",
            recognitionModelDisplayName: "MOSS",
            translationProviderID: "apple",
            translationProviderDisplayName: "Apple",
            segments: [
                segment(speaker: "S01", duration: 3),
                segment(speaker: "S02", duration: 3),
                segment(speaker: "S03", duration: 3),
                segment(speaker: "S04", duration: 3),
            ]
        )

        #expect(track.dominantConversationSpeakerIDs == nil)
    }

    @Test("Finds the closest subtitle segment for fuzzy seeking")
    func closestSegmentForFuzzySeeking() throws {
        let firstID = UUID()
        let secondID = UUID()
        let track = RealtimeHistoryTrack(
            recognitionModelID: "moss",
            recognitionModelDisplayName: "MOSS",
            translationProviderID: "apple",
            translationProviderDisplayName: "Apple",
            segments: [
                RealtimeHistoryTrackSegment(
                    id: firstID,
                    offset: 10,
                    duration: 5,
                    relation: .sourceOnly
                ),
                RealtimeHistoryTrackSegment(
                    id: secondID,
                    offset: 20,
                    duration: 5,
                    relation: .sourceOnly
                ),
            ]
        )

        #expect(track.closestSegmentID(to: 12) == firstID)
        #expect(track.closestSegmentID(to: 18) == secondID)
    }

    private func segment(speaker: String, duration: TimeInterval) -> RealtimeHistoryTrackSegment {
        RealtimeHistoryTrackSegment(
            offset: 0,
            duration: duration,
            speakerID: speaker,
            relation: .sourceOnly
        )
    }
}
