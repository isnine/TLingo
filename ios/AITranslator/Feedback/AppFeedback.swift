#if os(iOS)
// AppFeedback.swift — an in-app feedback form. What the person writes,
// plus up to four photos, goes to this application's independent platform environment.
//
// Copy this file and AirDeviceProof.swift into the app target, unchanged
// except for `FeedbackConfig.endpoint`, `FeedbackConfig.appKey` and
// `FeedbackConfig.teamID`. Requires no packages, no Info.plist entries, and
// no account: a public ingestion key authorizes submission only. iOS 17 or later.
//
// With the App Attest capability and `teamID` set, each entry carries the
// device's proof (AirDeviceProof.swift). Without them — and always on the
// Simulator — feedback is still sent and stored, marked unverified.
//
// Usage — present the form from anywhere:
//   .sheet(isPresented: $showFeedback) { FeedbackView() }
// or send without the form:
//   try await FeedbackClient.send(message: "…", images: [uiImage])
//
// The form's strings are plain English; localize them like the rest of the
// app if the app is localized.

import PhotosUI
import SwiftUI
import UIKit

enum FeedbackConfig {
    /// The `feedbackEndpoint` and public `key` returned by `workers app-key`.
    static let endpoint = AirFeedbackConfiguration.feedbackEndpoint
    static let appKey = AirFeedbackConfiguration.appKey
    /// The Apple team id (DEVELOPMENT_TEAM) for App Attest; nil sends no proof.
    static let teamID: String? = AirFeedbackConfiguration.teamID
    static let maximumImages = 4
}

enum FeedbackClient {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Sends one piece of feedback. Images are downscaled to 2048 px on the
    /// long side and sent as JPEG, so a report with four screenshots stays
    /// small enough for cellular. Main actor because the device strings come
    /// from `UIDevice`; the network wait does not block anything.
    @MainActor
    static func send(message: String, images: [UIImage]) async throws {
        guard message.utf16.count <= AirFeedbackConfiguration.maximumMessageLength else {
            throw Failure(message: String(localized: "Feedback must be 4000 characters or fewer."))
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let body: [String: Any] = [
            "message": message,
            "appVersion": info["CFBundleShortVersionString"] as? String ?? "",
            "appBuild": info["CFBundleVersion"] as? String ?? "",
            "deviceModel": deviceModel,
            "osVersion": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "locale": Locale.current.identifier,
            "images": images.prefix(FeedbackConfig.maximumImages).compactMap { image -> [String: String]? in
                guard let data = jpegData(image) else { return nil }
                return ["mediaType": "image/jpeg", "data": data.base64EncodedString()]
            },
        ]

        var request = URLRequest(url: FeedbackConfig.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(FeedbackConfig.appKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let bytes = try JSONSerialization.data(withJSONObject: body)
        request.httpBody = bytes
        request.timeoutInterval = 60
        // The proof signs these exact bytes; none is fine (stored unverified).
        let proof = await AirDeviceProof.headers(
            for: bytes, endpoint: FeedbackConfig.endpoint, appKey: FeedbackConfig.appKey, teamID: FeedbackConfig.teamID
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

    private static func jpegData(_ image: UIImage) -> Data? {
        let longest = max(image.size.width, image.size.height)
        let scale = min(1, 2048 / max(longest, 1))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return scaled.jpegData(compressionQuality: 0.8)
    }

    /// The hardware identifier (`iPhone17,2`), which is what a bug report needs;
    /// `UIDevice.model` only says "iPhone".
    private static var deviceModel: String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var images: [UIImage] = []
    @State private var sending = false
    @State private var loadingImages = false
    @State private var failure: String?
    @State private var sent = false

    private var canSend: Bool {
        !sending && !loadingImages && pickerItems.isEmpty && message.utf16.count <= AirFeedbackConfiguration.maximumMessageLength && (!message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty)
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
                                ForEach(images.indices, id: \.self) { index in
                                    Image(uiImage: images[index])
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 72, height: 72)
                                        .clipShape(RoundedRectangle(cornerRadius: 8))
                                        .overlay(alignment: .topTrailing) {
                                            Button {
                                                images.remove(at: index)
                                                pickerItems = []
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .symbolRenderingMode(.palette)
                                                    .foregroundStyle(.white, .black.opacity(0.6))
                                            }
                                            .padding(4)
                                            .accessibilityLabel("Remove Image")
                                            .disabled(sending || loadingImages || !pickerItems.isEmpty)
                                        }
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    PhotosPicker(
                        selection: $pickerItems,
                        maxSelectionCount: FeedbackConfig.maximumImages - images.count,
                        matching: .images
                    ) {
                        Label("Add Screenshots", systemImage: "photo.on.rectangle")
                    }
                    .accessibilityIdentifier("feedback_add_images")
                    .disabled(sending || loadingImages || !pickerItems.isEmpty || images.count >= FeedbackConfig.maximumImages)
                    if loadingImages {
                        ProgressView("Loading Images")
                    }
                } footer: {
                    Text("Up to \(FeedbackConfig.maximumImages) images. The app version and device model are sent along.")
                    Text("When you tap Send, your feedback, selected images, app version and build, device model, system version, and language and region are sent. Information that verifies the request comes from the app may also be included. Translation text, translation history, account information, local logs, and email drafts are not attached automatically. Avoid including passwords or other sensitive information in your feedback or images.")
                }
                if let failure {
                    Section {
                        Text(failure).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("feedback_cancel")
                        .disabled(sending || loadingImages || !pickerItems.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if sending {
                        ProgressView()
                    } else {
                        Button("Send") { send() }
                            .accessibilityIdentifier("feedback_send")
                            .disabled(!canSend)
                    }
                }
            }
            .task(id: pickerItems) {
                guard !pickerItems.isEmpty else { return }
                await load(pickerItems)
            }
            .alert("Thank you", isPresented: $sent) {
                Button("Done") { dismiss() }
            } message: {
                Text("Your feedback was sent.")
            }
            .interactiveDismissDisabled(sending || loadingImages || !pickerItems.isEmpty)
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        loadingImages = true
        failure = nil
        defer { loadingImages = false }
        for item in items {
            guard !Task.isCancelled else { return }
            guard images.count < FeedbackConfig.maximumImages else { break }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data)
            else {
                guard !Task.isCancelled else { return }
                failure = String(localized: "One or more images could not be loaded.")
                continue
            }
            guard !Task.isCancelled else { return }
            images.append(image)
        }
        pickerItems = []
    }

    private func send() {
        guard canSend else { return }
        sending = true
        failure = nil
        let submittedMessage = message
        let submittedImages = images
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
