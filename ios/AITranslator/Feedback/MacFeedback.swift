#if os(macOS)
import AppKit
import Darwin
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Native Mac counterpart to the iOS template: the same anonymous wire schema,
/// public ingestion key and optional proof, with only manually selected images.
enum FeedbackClient {
    nonisolated struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func send(message: String, images: [Data]) async throws {
        guard message.utf16.count <= AirFeedbackConfiguration.maximumMessageLength else {
            throw Failure(message: String(localized: "Feedback must be 4000 characters or fewer."))
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let body: [String: Any] = [
            "message": message,
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "",
            "appBuild": info["CFBundleVersion"] as? String ?? "",
            "deviceModel": deviceModel,
            "osVersion": "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "locale": Locale.current.identifier,
            "images": images.prefix(AirFeedbackConfiguration.maximumImages).map {
                ["mediaType": "image/jpeg", "data": $0.base64EncodedString()]
            },
        ]
        let endpoint = AirFeedbackConfiguration.feedbackEndpoint
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(AirFeedbackConfiguration.appKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bytes = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bytes
        request.timeoutInterval = 60
        let proof = await AirDeviceProof.headers(
            for: bytes, endpoint: endpoint, appKey: AirFeedbackConfiguration.appKey,
            teamID: AirFeedbackConfiguration.teamID
        )
        for (name, value) in proof {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: String(localized: "No response from the server."))
        }
        if !proof.isEmpty {
            await AirDeviceProof.handle(status: http.value(forHTTPHeaderField: "X-Attest-Status"))
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw Failure(message: String(localized: "The server answered \(http.statusCode)."))
        }
    }

    private static var deviceModel: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "Mac" }
        var model = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &model, &size, nil, 0) == 0 else { return "Mac" }
        return String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
    }
}

private nonisolated enum FeedbackImageLoader {
    static func load(_ urls: [URL]) throws -> [Data] {
        try urls.map { url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Decode a bounded thumbnail, honor orientation, and re-encode pixels
            // only: no original file name, path, EXIF or other image metadata.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let data = NSBitmapImageRep(cgImage: thumbnail).representation(
                      using: .jpeg, properties: [.compressionFactor: 0.8]
                  ), data.count <= 8 * 1024 * 1024
            else {
                throw FeedbackClient.Failure(message: String(localized: "One or more images could not be loaded."))
            }
            return data
        }
    }
}

struct FeedbackView: View {
    private struct SelectedImage: Identifiable {
        let id = UUID()
        let jpeg: Data
    }

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var images: [SelectedImage] = []
    @State private var showImporter = false
    @State private var loadingImages = false
    @State private var imageLoadTask: Task<Void, Never>?
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    private var canSend: Bool {
        !sending && !loadingImages && !showImporter
            && message.utf16.count <= AirFeedbackConfiguration.maximumMessageLength
            && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What happened, or what would you like to see?", text: $message, axis: .vertical)
                        .lineLimit(5 ... 12)
                        .accessibilityIdentifier("feedback_message")
                        .disabled(sending)
                        .onChange(of: message) { _, value in
                            message = AirFeedbackConfiguration.limitedMessage(value)
                        }
                }
                Section {
                    if !images.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 8) {
                                ForEach(images) { image in
                                    if let preview = NSImage(data: image.jpeg) {
                                        Image(nsImage: preview)
                                            .resizable()
                                            .scaledToFill()
                                            .frame(width: 72, height: 72)
                                            .clipShape(RoundedRectangle(cornerRadius: 8))
                                            .overlay(alignment: .topTrailing) {
                                                Button {
                                                    images.removeAll { $0.id == image.id }
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                }
                                                .buttonStyle(.borderless)
                                                .accessibilityLabel("Remove Image")
                                                .disabled(sending || loadingImages)
                                                .padding(4)
                                            }
                                    }
                                }
                            }
                        }
                    }
                    Button {
                        showImporter = true
                    } label: {
                        Label("Add Screenshots", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("feedback_add_images")
                    .disabled(sending || loadingImages || images.count >= AirFeedbackConfiguration.maximumImages)
                    if loadingImages {
                        ProgressView("Loading Images")
                    }
                } footer: {
                    Text("Up to \(AirFeedbackConfiguration.maximumImages) images. The app version and device model are sent along.")
                    Text("When you tap Send, your feedback, selected images, app version and build, device model, system version, and language and region are sent. Information that verifies the request comes from the app may also be included. Translation text, translation history, account information, local logs, and email drafts are not attached automatically. Avoid including passwords or other sensitive information in your feedback or images.")
                }
                if let failure {
                    Section {
                        Label { Text(failure) } icon: { Image(systemName: "exclamationmark.triangle") }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Send Feedback")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("feedback_cancel")
                        .keyboardShortcut(.cancelAction)
                        .disabled(sending || loadingImages)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send") { send() }
                            .accessibilityIdentifier("feedback_send")
                            .keyboardShortcut(.defaultAction)
                            .disabled(!canSend)
                    }
                }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
                load(result)
            }
            .alert("Thank you", isPresented: $sent) {
                Button("Done") { dismiss() }
            } message: {
                Text("Your feedback was sent.")
            }
            .interactiveDismissDisabled(sending || loadingImages)
            .onDisappear { imageLoadTask?.cancel() }
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 420, idealHeight: 520)
    }

    private func load(_ result: Result<[URL], Error>) {
        guard !sending, !loadingImages else { return }
        do {
            let urls = try result.get()
            guard !urls.isEmpty else { return }
            guard urls.count <= AirFeedbackConfiguration.maximumImages - images.count else {
                throw FeedbackClient.Failure(message: String(localized: "Choose up to 4 images."))
            }
            loadingImages = true
            failure = nil
            imageLoadTask = Task {
                defer { loadingImages = false; imageLoadTask = nil }
                do {
                    let loaded = try await Task.detached { try FeedbackImageLoader.load(urls) }.value
                    guard !Task.isCancelled else { return }
                    images.append(contentsOf: loaded.map { SelectedImage(jpeg: $0) })
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func send() {
        guard canSend else { return }
        sending = true
        failure = nil
        let submittedMessage = message
        let submittedImages = images.map(\.jpeg)
        Task {
            do {
                try await FeedbackClient.send(message: submittedMessage, images: submittedImages)
                sent = true
            } catch {
                failure = error.localizedDescription
            }
            sending = false
        }
    }
}
#endif
