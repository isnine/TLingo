#if os(macOS) || os(iOS)
    import Foundation

    enum RealtimeCaptureError: LocalizedError {
        #if os(macOS)
        case screenRecordingNotGranted
        case systemAudioCaptureStopped
        case microphoneCaptureInterrupted
        case microphoneCaptureRuntimeError(String?)
        #endif
        case microphoneNotGranted
        case microphoneUnavailable
        #if os(macOS)
        case noDisplay
        #endif
        case speechNotAuthorized
        case speechRecognizerUnavailable
        case speechRecognitionEndedUnexpectedly

        var errorDescription: String? {
            switch self {
            #if os(macOS)
            case .screenRecordingNotGranted:
                return String(localized: "Screen and system audio recording access is required for Mac Audio.")
            case .systemAudioCaptureStopped:
                return String(localized: "Mac Audio capture stopped unexpectedly. End Realtime and start realtime again.")
            case .microphoneCaptureInterrupted:
                return String(localized: "Microphone capture was interrupted. End Realtime and start realtime again.")
            case let .microphoneCaptureRuntimeError(reason):
                let trimmedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !trimmedReason.isEmpty else {
                    return String(localized: "Microphone capture stopped unexpectedly. End Realtime and start realtime again.")
                }
                return String(localized: "Microphone capture stopped unexpectedly. \(trimmedReason) End Realtime and start realtime again.")
            #endif
            case .microphoneNotGranted:
                return String(localized: "Microphone access is required for microphone input.")
            case .microphoneUnavailable:
                return String(localized: "No available microphone was found.")
            #if os(macOS)
            case .noDisplay:
                return String(localized: "No active display was found for system audio capture.")
            #endif
            case .speechNotAuthorized:
                return String(localized: "Speech recognition access is required for realtime subtitles.")
            case .speechRecognizerUnavailable:
                return String(localized: "Speech recognition is not available for the selected source language.")
            case .speechRecognitionEndedUnexpectedly:
                return String(localized: "Speech recognition ended unexpectedly. End Realtime and start realtime again.")
            }
        }
    }
#endif
