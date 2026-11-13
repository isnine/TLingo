import PhotosUI
import SwiftUI

/// Bottom input bar shared by all conversation surfaces.
public struct ConversationInputBar: View {
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    @Binding var selectedModel: ModelConfig
    let isStreaming: Bool
    let canSend: Bool
    let availableModels: [ModelConfig]
    let images: [ImageAttachment]
    let onRemoveImage: ((UUID) -> Void)?
    let onAddImages: (([PlatformImage]) -> Void)?
    let onRequiresPro: (() -> Void)?
    let placeholder: String
    let focusOnAppear: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var editorHeight: CGFloat = 36
    @State private var showModelSelectionSheet = false
    #if os(iOS)
        @State private var isPhotoPickerPresented = false
        @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    @ThemeColors private var colors: AppColorPalette

    public init(
        text: Binding<String>,
        selectedModel: Binding<ModelConfig>,
        isStreaming: Bool,
        canSend: Bool,
        availableModels: [ModelConfig] = [],
        images: [ImageAttachment] = [],
        onRemoveImage: ((UUID) -> Void)? = nil,
        onAddImages: (([PlatformImage]) -> Void)? = nil,
        onRequiresPro: (() -> Void)? = nil,
        placeholder: String = String(localized: "Ask for follow-up changes"),
        focusOnAppear: Bool = false,
        onSend: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        _text = text
        _selectedModel = selectedModel
        self.isStreaming = isStreaming
        self.canSend = canSend
        self.availableModels = availableModels
        self.images = images
        self.onRemoveImage = onRemoveImage
        self.onAddImages = onAddImages
        self.onRequiresPro = onRequiresPro
        self.placeholder = placeholder
        self.focusOnAppear = focusOnAppear
        self.onSend = onSend
        self.onStop = onStop
    }

    public var body: some View {
        #if os(macOS)
            inputSurface
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        #else
            inputSurface
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 12)
        #endif
    }

    @ViewBuilder
    private var inputSurface: some View {
        #if os(macOS)
            inputSurfaceContent
        #else
            if #available(iOS 26.0, macOS 26.0, *) {
                GlassEffectContainer(spacing: 8) {
                    inputSurfaceContent
                }
            } else {
                inputSurfaceContent
            }
        #endif
    }

    private var inputSurfaceContent: some View {
        VStack(spacing: 8) {
            if !images.isEmpty {
                ImageAttachmentPreview(
                    images: images,
                    onRemove: { id in
                        onRemoveImage?(id)
                    }
                )
                .padding(.horizontal, 44)
            }

            HStack(alignment: .bottom, spacing: 8) {
                if onAddImages != nil {
                    addMenu
                }

                composerSurface
            }
        }
    }

    private var composerSurface: some View {
        HStack(alignment: .bottom, spacing: 4) {
            textEditor

            if !availableModels.isEmpty {
                modelSelectionButton
                    .padding(.vertical, 4)
            }

            actionButton
                .padding(4)
        }
        .tlingoGlassCapsule(.chrome)
    }

    @ViewBuilder
    private var textEditor: some View {
        #if os(macOS)
            AutoPasteTextEditor(
                text: $text,
                placeholder: placeholder,
                onImagePaste: { nsImages in
                    onAddImages?(nsImages)
                },
                onContentHeightChange: updateEditorHeight,
                onSubmit: {
                    if canSend {
                        onSend()
                    }
                },
                fontSize: 13,
                textContainerInset: NSSize(width: 4, height: 2),
                showsVerticalScroller: false,
                hidePlaceholderWhenFocused: true,
                autoFocus: focusOnAppear
            )
            .frame(height: editorHeight, alignment: .topLeading)
            .padding(.leading, 12)
        #else
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 14))
                        .foregroundColor(colors.textSecondary)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }

                AutoPasteTextEditor(
                    text: $text,
                    placeholder: placeholder,
                    onPaste: { _ in },
                    onImagePaste: { uiImages in
                        onAddImages?(uiImages)
                    },
                    onContentHeightChange: updateEditorHeight,
                    onSubmit: {
                        if canSend {
                            onSend()
                        }
                    },
                    autoFocus: focusOnAppear
                )
            }
            .frame(height: editorHeight, alignment: .topLeading)
            .padding(.leading, 12)
        #endif
    }

    private func updateEditorHeight(_ height: CGFloat) {
        editorHeight = min(max(height, 36), 92)
    }

    private var addMenu: some View {
        Menu {
            imageMenuItem
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(colors.textPrimary)
                .frame(width: 40, height: 40)
                .tlingoGlassCircle(.control, interactive: true)
        }
        .buttonStyle(.plain)
        .disabled(onAddImages == nil)
        .help("Add Image")
        .accessibilityLabel("Add Image")
        #if os(iOS)
            .photosPicker(
                isPresented: $isPhotoPickerPresented,
                selection: $selectedPhotoItems,
                matching: .images,
                photoLibrary: .shared()
            )
            .task(id: selectedPhotoItems) {
                await loadSelectedPhotos()
            }
        #endif
    }

    private var modelSelectionButton: some View {
        Button {
            showModelSelectionSheet = true
        } label: {
            HStack(spacing: 5) {
                Text(selectedModel.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "cpu")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.65)
            }
            .foregroundColor(colors.textPrimary)
            .frame(width: 132, alignment: .trailing)
            .frame(minHeight: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Models")
        .accessibilityValue(selectedModel.displayName)
        .accessibilityIdentifier("conversation_model_picker")
        .sheet(isPresented: $showModelSelectionSheet) {
            ModelSelectionSheet(
                selectedModel: $selectedModel,
                availableModels: availableModels,
                onRequiresPro: onRequiresPro
            )
        }
    }

    @ViewBuilder
    private var imageMenuItem: some View {
        if onAddImages != nil {
            #if os(macOS)
                Button("Paste Image", systemImage: "photo.on.rectangle.angled") {
                    pasteImageFromClipboard()
                }
            #else
                Button("Add Image", systemImage: "photo.on.rectangle.angled") {
                    isPhotoPickerPresented = true
                }
            #endif
        }
    }

    #if os(iOS)
        private func loadSelectedPhotos() async {
            let items = selectedPhotoItems
            guard !items.isEmpty else { return }
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data)
                {
                    guard !Task.isCancelled else { return }
                    onAddImages?([image])
                }
            }
            selectedPhotoItems = []
        }
    #endif

    #if os(macOS)
        private func pasteImageFromClipboard() {
            let pb = NSPasteboard.general
            if let image = pb.imageFromData() {
                onAddImages?([image])
                return
            }
            let images = pb.imagesFromFileURLs()
            if !images.isEmpty {
                onAddImages?(images)
            }
        }
    #endif

    // MARK: - Send / Stop Button

    @ViewBuilder
    private var actionButton: some View {
        if isStreaming {
            Button(action: onStop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(colors.onAccent)
                    .frame(width: 32, height: 32)
                    .tlingoGlassCircle(.destructive, interactive: true)
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(canSend ? colors.onAccent : colors.textSecondary.opacity(0.45))
                    .frame(width: 32, height: 32)
                    .tlingoGlassCircle(canSend ? .prominent : .control, interactive: canSend)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }
}
