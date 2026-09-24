#if os(macOS) && arch(arm64)
    import Foundation
    import Testing

    @testable import ShareCore

    @Suite("Realtime history MOSS reconstruction")
    struct RealtimeHistoryMOSSReconstructorTests {
        @Test("Maps MOSS timestamps and speaker labels")
        func mapsSegments() {
            let segments = RealtimeHistoryMOSSReconstructor.transcriptSegments(
                from: [
                    [
                        "start": 1.25,
                        "end": 3.75,
                        "speaker_id": "S01",
                        "text": "[S01] Hello there.",
                    ],
                    [
                        "start": NSNumber(value: 4.0),
                        "end": NSNumber(value: 5.0),
                        "text": "[S02] Reply.",
                    ],
                ],
                source: .microphone,
                recordingDuration: 10
            )

            #expect(segments.map(\.offset) == [1.25, 4])
            #expect(segments.map(\.duration) == [2.5, 1])
            #expect(segments.map(\.speakerID) == ["S01", "S02"])
            #expect(segments.map(\.text) == ["Hello there.", "Reply."])
        }

        @Test("Scopes speaker labels after the inference window boundary")
        func scopesLongRecordingSpeakers() {
            let segments = RealtimeHistoryMOSSReconstructor.transcriptSegments(
                from: [
                    [
                        "start": 301.0,
                        "end": 302.0,
                        "speaker_id": "S01",
                        "text": "[S01] Next part.",
                    ],
                ],
                source: .macAudio,
                recordingDuration: 3600
            )

            #expect(segments.first?.speakerID == "P2-S01")
        }

        @Test("Parses only completed streaming speaker segments")
        func parsesStreamingSegments() {
            var ids: [String: UUID] = [:]
            let segments = RealtimeHistoryMOSSReconstructor.streamingTrackSegments(
                from: "[0.96][S01] Hello.[6.42][6.82][S02] Reply.[8.10][9.00][S01] Incomplete",
                source: .microphone,
                ids: &ids
            )

            #expect(segments.map(\.offset) == [0.96, 6.82])
            #expect(abs((segments.first?.duration ?? 0) - 5.46) < 0.001)
            #expect(abs((segments.last?.duration ?? 0) - 1.28) < 0.001)
            #expect(segments.map(\.speakerID) == ["S01", "S02"])
            #expect(segments.map(\.sourceText) == ["Hello.", "Reply."])
        }

        @Test("Timeline duration includes recording gaps")
        func timelineDurationIncludesGaps() {
            let recording = RealtimeHistoryAudioRecording(
                source: .macAudio,
                directoryName: "fixture",
                sampleRate: 16000,
                channelCount: 1,
                segments: [
                    RealtimeHistoryAudioSegment(
                        relativePath: "fixture/one.m4a",
                        offset: 0,
                        duration: 2,
                        byteCount: 1
                    ),
                    RealtimeHistoryAudioSegment(
                        relativePath: "fixture/two.m4a",
                        offset: 5,
                        duration: 3,
                        byteCount: 1
                    ),
                ]
            )

            #expect(RealtimeHistoryAudioTimeline.duration(for: recording) == 8)
        }
    }
#endif
