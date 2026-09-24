//
//  TTSPreviewService.swift
//  ShareCore
//
//  Created by AI Assistant on 2025/02/02.
//

import AVFoundation
import Combine
import Foundation
import os

private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "TTSPreviewService")

/// Service for playing TTS voice previews from the Worker API
public final class TTSPreviewService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    public static let shared = TTSPreviewService()

    /// Fixed preview text for voice samples
    public static let previewText = "Hello, this is a sample voice preview."

    /// TTS model to use for preview
    private static let ttsModel = "gpt-4o-mini-tts"

    @Published public private(set) var isPlaying = false
    @Published public private(set) var currentVoiceID: String?
    /// ID of the text currently being spoken (for tracking which result is playing)
    @Published public private(set) var currentTextID: String?

    private let urlSession: URLSession
    private var audioPlayer: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, Never>?

    public init(urlSession: URLSession = NetworkSession.shared) {
        self.urlSession = urlSession
        super.init()
    }

    /// Speaks the given text using the user's selected voice
    /// - Parameters:
    ///   - text: The text to speak
    ///   - textID: Optional identifier to track which text is being spoken (e.g., runID)
    @MainActor
    public func speak(text: String, textID: String? = nil) async {
        let voiceID = AppPreferences.shared.selectedVoiceID

        // Stop any current playback
        stopPlayback()

        isPlaying = true
        currentVoiceID = voiceID
        currentTextID = textID

        do {
            let audioData = try await fetchTTSAudio(text: text, voiceID: voiceID)
            try await playAudio(data: audioData)
        } catch {
            logger.error("TTS playback failed: \(error, privacy: .public)")
        }

        isPlaying = false
        currentVoiceID = nil
        currentTextID = nil
    }

    /// Plays a TTS preview for the specified voice
    /// - Parameter voiceID: The voice ID to preview (e.g., "alloy")
    @MainActor
    public func playPreview(voiceID: String) async {
        // Stop any current playback
        stopPlayback()

        isPlaying = true
        currentVoiceID = voiceID

        do {
            let audioData = try await fetchTTSAudio(text: Self.previewText, voiceID: voiceID)
            try await playAudio(data: audioData)
        } catch {
            logger.error("Preview failed for voice '\(voiceID, privacy: .public)': \(error, privacy: .public)")
        }

        isPlaying = false
        currentVoiceID = nil
    }

    /// Stops any current audio playback
    @MainActor
    public func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentVoiceID = nil
        currentTextID = nil
        playbackContinuation?.resume()
        playbackContinuation = nil
    }

    /// Check if currently speaking a specific text ID
    public func isSpeaking(textID: String) -> Bool {
        isPlaying && currentTextID == textID
    }

    // MARK: - AVAudioPlayerDelegate

    public func audioPlayerDidFinishPlaying(_: AVAudioPlayer, successfully _: Bool) {
        playbackContinuation?.resume()
        playbackContinuation = nil
    }

    // MARK: - Private Methods

    private func fetchTTSAudio(text: String, voiceID: String) async throws -> Data {
        let url = CloudServiceConstants.endpoint.appendingPathComponent("tts")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")

        let path = "/tts"
        CloudAuthHelper.applyAuth(to: &request, path: path)

        let body: [String: Any] = [
            "model": Self.ttsModel,
            "input": text,
            "voice": voiceID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        logger.debug("Requesting TTS for voice: \(voiceID, privacy: .public), text length: \(text.count, privacy: .public)")

        let (data, response) = try await urlSession.data(for: request)

        let httpResponse = try response.asHTTP(or: TTSPreviewError.invalidResponse)

        guard (200 ... 299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw TTSPreviewError.httpError(statusCode: httpResponse.statusCode, body: body)
        }

        logger.debug("Received \(data.count, privacy: .public) bytes of audio data")
        return data
    }

    @MainActor
    private func playAudio(data: Data) async throws {
        #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .default)
            try audioSession.setActive(true)
        #endif

        audioPlayer = try AVAudioPlayer(data: data)
        audioPlayer?.delegate = self
        audioPlayer?.prepareToPlay()
        guard audioPlayer?.play() == true else {
            throw TTSPreviewError.playbackFailed
        }

        await withCheckedContinuation { continuation in
            playbackContinuation = continuation
        }
    }
}

// MARK: - Error Types

public enum TTSPreviewError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int, body: String?)
    case playbackFailed

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return String(localized: "Invalid response from TTS service")
        case let .httpError(statusCode, body):
            if let body {
                return String(localized: "HTTP \(statusCode): \(body)")
            }
            return String(localized: "HTTP error \(statusCode)")
        case .playbackFailed:
            return String(localized: "Failed to play audio")
        }
    }
}
