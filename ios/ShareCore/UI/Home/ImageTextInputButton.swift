//
//  ImageTextInputButton.swift
//  ShareCore
//

#if os(iOS)
    import os
    import PhotosUI
    import SwiftUI
    import UIKit

    private let logger = os.Logger(subsystem: "com.zanderwang.AITranslator", category: "ImageTextInput")

    /// Takes or picks a photo, runs OCR, and hands the recognized text to the input field.
    struct ImageTextInputButton: View {
        let tint: Color
        let onRecognizedText: (String) -> Void

        @State private var showsCamera = false
        @State private var showsPhotoPicker = false
        @State private var selectedPhoto: PhotosPickerItem?
        @State private var isRecognizing = false
        @State private var showsNoTextAlert = false

        var body: some View {
            Menu {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo", systemImage: "camera") { showsCamera = true }
                }
                Button("Choose Photo", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
            } label: {
                Group {
                    if isRecognizing {
                        ProgressView()
                    } else {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: 14))
                    }
                }
                .frame(width: 20, height: 20)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .tint(tint)
            .disabled(isRecognizing)
            .accessibilityLabel("Translate Image Text")
            .accessibilityIdentifier("home_image_text_button")
            .photosPicker(isPresented: $showsPhotoPicker, selection: $selectedPhoto, matching: .images)
            .fullScreenCover(isPresented: $showsCamera) {
                CameraCaptureView { image in
                    showsCamera = false
                    if let image {
                        recognize(image)
                    }
                }
                .ignoresSafeArea()
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                selectedPhoto = nil
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data)
                    else {
                        showsNoTextAlert = true
                        return
                    }
                    recognize(image)
                }
            }
            .alert("No Text Found", isPresented: $showsNoTextAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Try a sharper photo with the text filling more of the frame.")
            }
        }

        private func recognize(_ image: UIImage) {
            isRecognizing = true
            Task {
                defer { isRecognizing = false }
                let signposter = PerformanceSignposts.signposter
                let interval = signposter.beginInterval("Image OCR", id: signposter.makeSignpostID())
                defer { signposter.endInterval("Image OCR", interval) }
                do {
                    guard let cgImage = Self.uprightImage(image).cgImage else {
                        showsNoTextAlert = true
                        return
                    }
                    let text = try await OCRTextRecognizer.recognizeText(in: cgImage)
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showsNoTextAlert = true
                    } else {
                        onRecognizedText(text)
                    }
                } catch {
                    logger.error("OCR failed: \(error.localizedDescription, privacy: .public)")
                    showsNoTextAlert = true
                }
            }
        }

        /// Vision reads raw pixels, so camera photos must be redrawn upright; large photos are scaled down for speed.
        private static func uprightImage(_ image: UIImage, maxDimension: CGFloat = 3000) -> UIImage {
            let longest = max(image.size.width, image.size.height)
            let scale = longest > maxDimension ? maxDimension / longest : 1
            guard image.imageOrientation != .up || scale < 1 else { return image }
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
        }
    }

    private struct CameraCaptureView: UIViewControllerRepresentable {
        let onFinish: (UIImage?) -> Void

        func makeUIViewController(context: Context) -> UIImagePickerController {
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = context.coordinator
            return picker
        }

        func updateUIViewController(_: UIImagePickerController, context _: Context) {}

        func makeCoordinator() -> Coordinator {
            Coordinator(onFinish: onFinish)
        }

        final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
            let onFinish: (UIImage?) -> Void

            init(onFinish: @escaping (UIImage?) -> Void) {
                self.onFinish = onFinish
            }

            func imagePickerController(
                _: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
            ) {
                onFinish(info[.originalImage] as? UIImage)
            }

            func imagePickerControllerDidCancel(_: UIImagePickerController) {
                onFinish(nil)
            }
        }
    }
#endif
