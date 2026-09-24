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
    #if os(iOS)
        @State private var isPhotoPickerPresented = false
        @State private var selectedPhotoItems: [PhotosPickerItem] = []
    #endif

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

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
                addMenu

                composerSurface
            }
        }
    }

    private var composerSurface: some View {
        HStack(alignment: .bottom, spacing: 4) {
            textEditor

            actionButton
                .padding(4)
        }
        .tlingoGlassCapsule(
            tint: colors.cardBackground.opacity(colorScheme == .dark ? 0.12 : 0.18),
            fallbackTint: colors.cardBackground.opacity(colorScheme == .dark ? 0.16 : 0.72),
            fallbackStroke: colors.divider
        )
    }

    @ViewBuilder
    private var textEditor: some View {
        #if os(macOS)
            ConversationPasteTextEditor(
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
                }
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

            if !availableModels.isEmpty {
                ModelPickerMenu(
                    selectedModel: $selectedModel,
                    availableModels: availableModels,
                    onRequiresPro: onRequiresPro
                )
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(colors.textPrimary)
                .frame(width: 40, height: 40)
                .tlingoGlassCircle(
                    tint: colors.cardBackground.opacity(colorScheme == .dark ? 0.10 : 0.14),
                    interactive: true,
                    fallbackTint: colors.cardBackground.opacity(colorScheme == .dark ? 0.16 : 0.72),
                    fallbackStroke: colors.divider
                )
        }
        .buttonStyle(.plain)
        .disabled(onAddImages == nil && availableModels.isEmpty)
        .help("Add Image or Change Model")
        .accessibilityLabel("Add Image or Change Model")
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

    private var actionButton: some View {
        Group {
            if isStreaming {
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .tlingoGlassCircle(
                            tint: colors.error.opacity(0.78),
                            interactive: true,
                            fallbackTint: colors.error,
                            fallbackStroke: colors.error.opacity(0.25)
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(canSend ? colors.background : colors.textSecondary.opacity(0.45))
                        .frame(width: 32, height: 32)
                        .tlingoGlassCircle(
                            tint: canSend ? colors.textPrimary.opacity(0.82) : colors.cardBackground.opacity(
                                colorScheme == .dark ? 0.10 : 0.14
                            ),
                            interactive: canSend,
                            fallbackTint: canSend ? colors.textPrimary : colors.chipSecondaryBackground.opacity(0.45),
                            fallbackStroke: canSend ? colors.textPrimary.opacity(0.25) : colors.divider
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
    }
}

// MARK: - macOS Paste-Aware Text Editor for Conversation Input

#if os(macOS)
    /// A lightweight NSViewRepresentable text editor that supports image paste and drag & drop
    /// for use inside ConversationInputBar.
    private struct ConversationPasteTextEditor: NSViewRepresentable {
        @Binding var text: String
        let placeholder: String
        var onImagePaste: (([NSImage]) -> Void)?
        var onContentHeightChange: ((CGFloat) -> Void)?
        var onSubmit: (() -> Void)?

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        func makeNSView(context: Context) -> NSScrollView {
            let textView = ConversationPasteTextView()
            textView.delegate = context.coordinator
            textView.isRichText = false
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 4, height: 2)
            textView.textContainer?.lineFragmentPadding = 0
            textView.font = NSFont.systemFont(ofSize: 13)
            textView.isHorizontallyResizable = false
            textView.textContainer?.widthTracksTextView = true
            textView.string = text
            textView.onImagePaste = onImagePaste
            textView.onSubmit = onSubmit
            textView.placeholderString = placeholder

            textView.registerForDraggedTypes([.fileURL, .tiff, .png, NSPasteboard.PasteboardType("public.jpeg")])

            context.coordinator.textView = textView

            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = false
            scrollView.contentView.drawsBackground = false
            scrollView.documentView = textView
            return scrollView
        }

        func updateNSView(_ nsView: NSScrollView, context: Context) {
            guard let textView = nsView.documentView as? ConversationPasteTextView else { return }
            context.coordinator.update(parent: self)
            if textView.string != text {
                textView.string = text
            }
            textView.onImagePaste = onImagePaste
            textView.onSubmit = onSubmit
            context.coordinator.reportContentHeight(for: textView)
        }

        final class Coordinator: NSObject, NSTextViewDelegate {
            private var parent: ConversationPasteTextEditor
            private var lastReportedContentHeight: CGFloat = 0
            private var eventMonitor: Any?
            weak var textView: ConversationPasteTextView?

            init(parent: ConversationPasteTextEditor) {
                self.parent = parent
                super.init()
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self, let textView = self.textView else { return event }
                    guard textView.window?.isKeyWindow == true,
                          textView.window?.firstResponder === textView else { return event }

                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                    let isReturnKey = event.keyCode == 36 || event.keyCode == 76
                    if isReturnKey, flags == .shift {
                        textView.onSubmit?()
                        return nil
                    }
                    if isReturnKey, flags == .command {
                        textView.onSubmit?()
                        return nil
                    }

                    // Intercept Cmd+V for image paste
                    if flags == .command,
                       event.charactersIgnoringModifiers == "v"
                    {
                        textView.paste(nil)
                        return nil
                    }
                    return event
                }
            }

            func update(parent: ConversationPasteTextEditor) {
                self.parent = parent
            }

            deinit {
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                }
            }

            func textDidChange(_ notification: Notification) {
                guard let textView = notification.object as? NSTextView else { return }
                let updated = textView.string
                if parent.text != updated {
                    parent.text = updated
                }
                reportContentHeight(for: textView)
            }

            func reportContentHeight(for textView: NSTextView) {
                guard let layoutManager = textView.layoutManager,
                      let textContainer = textView.textContainer
                else { return }

                layoutManager.ensureLayout(for: textContainer)
                let usedRect = layoutManager.usedRect(for: textContainer)
                let height = ceil(usedRect.height + textView.textContainerInset.height * 2)
                guard abs(height - lastReportedContentHeight) > 0.5 else { return }
                lastReportedContentHeight = height
                DispatchQueue.main.async { [parent] in
                    parent.onContentHeightChange?(height)
                }
            }
        }
    }

    private final class ConversationPasteTextView: NSTextView {
        var onImagePaste: (([NSImage]) -> Void)?
        var onSubmit: (() -> Void)?
        var placeholderString: String? {
            didSet { needsDisplay = true }
        }

        override func paste(_ sender: Any?) {
            // Only handle image paste when this text view has focus.
            // Prevents images from appearing in the wrong input field
            // when multiple text views coexist.
            guard window?.firstResponder === self else {
                super.paste(sender)
                return
            }

            let pb = NSPasteboard.general
            if let image = pb.imageFromData() {
                onImagePaste?([image])
                return
            }
            let urlImages = pb.imagesFromFileURLs()
            if !urlImages.isEmpty {
                onImagePaste?(urlImages)
                return
            }

            super.paste(sender)
        }

        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isReturnKey = event.keyCode == 36 || event.keyCode == 76
            if isReturnKey, flags == .shift {
                onSubmit?()
                return
            }
            if isReturnKey, flags == .command {
                onSubmit?()
                return
            }
            super.keyDown(with: event)
        }

        // MARK: - Drag & Drop

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            if sender.draggingPasteboard.containsImage {
                return .copy
            }
            return super.draggingEntered(sender)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            let pb = sender.draggingPasteboard

            let urlImages = pb.imagesFromFileURLs()
            if !urlImages.isEmpty {
                onImagePaste?(urlImages)
                return true
            }

            if let image = pb.imageFromData() {
                onImagePaste?([image])
                return true
            }

            return super.performDragOperation(sender)
        }

        // MARK: - Placeholder

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty,
                  window?.firstResponder !== self,
                  let placeholder = placeholderString
            else {
                return
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: font ?? NSFont.systemFont(ofSize: 13),
            ]
            let inset = textContainerInset
            let padding = textContainer?.lineFragmentPadding ?? 0
            let origin = CGPoint(x: inset.width + padding, y: inset.height)
            NSAttributedString(string: placeholder, attributes: attrs).draw(at: origin)
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if result { needsDisplay = true }
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            if result { needsDisplay = true }
            return result
        }

        override func didChangeText() {
            super.didChangeText()
            needsDisplay = true
        }
    }
#endif
