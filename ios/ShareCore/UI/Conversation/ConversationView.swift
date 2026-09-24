import SwiftUI

/// Standalone conversation content without NavigationStack wrapper.
/// Used by the macOS inspector panel and can be embedded in any container.
/// When `onBack` is provided, shows a chevron-left back button in the header (push-style).
/// When only `onDismiss` is provided, shows an xmark close button (panel-style).
public struct ConversationContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var entitlement = Entitlement.shared
    @StateObject private var viewModel: ConversationViewModel
    @State private var showPremiumModelAlert = false
    @State private var showModelChooser = false
    #if os(iOS)
        @State private var isAutoFollowingStreaming = true
        @State private var conversationViewportHeight: CGFloat = 0
        @State private var conversationFrontierY: CGFloat = .infinity
    #endif

    private let onBack: (() -> Void)?
    private let onDismiss: (() -> Void)?
    private let onPremiumRequired: (() -> Void)?
    private let backgroundColor: Color?
    private let inputPlaceholder: String
    private let focusInputOnAppear: Bool
    private let onStreamingChanged: ((Bool) -> Void)?
    private let onStopHandlerReady: ((@escaping () -> Void) -> Void)?

    private var colors: AppColorPalette {
        AppColors.palette(for: colorScheme)
    }

    private var conversationBackground: Color {
        backgroundColor ?? colors.cardBackground
    }

    private var messageHorizontalPadding: CGFloat {
        #if os(macOS)
            28
        #else
            16
        #endif
    }

    public init(
        session: ConversationSession,
        onBack: (() -> Void)? = nil,
        onDismiss: (() -> Void)? = nil,
        onPremiumRequired: (() -> Void)? = nil,
        backgroundColor: Color? = nil,
        inputPlaceholder: String = String(localized: "Ask for follow-up changes"),
        focusInputOnAppear: Bool = false,
        onStreamingChanged: ((Bool) -> Void)? = nil,
        onStopHandlerReady: ((@escaping () -> Void) -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: ConversationViewModel(session: session))
        self.onBack = onBack
        self.onDismiss = onDismiss
        self.onPremiumRequired = onPremiumRequired
        self.backgroundColor = backgroundColor
        self.inputPlaceholder = inputPlaceholder
        self.focusInputOnAppear = focusInputOnAppear
        self.onStreamingChanged = onStreamingChanged
        self.onStopHandlerReady = onStopHandlerReady
    }

    private var showHeader: Bool {
        onBack != nil || onDismiss != nil
    }

    private var canUseSelectedModel: Bool {
        viewModel.canUseSelectedModel(isPro: entitlement.isPro)
    }

    private var freeModels: [ModelConfig] {
        viewModel.availableModels.filter { !$0.isPremium }
    }

    public var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                header

                Divider()
                    .foregroundColor(colors.divider)
            }

            messageList

            if let error = viewModel.errorMessage {
                errorBanner(error)
            }

            inputBar
        }
        .background(conversationBackground)
        #if os(macOS)
            .onKeyPress(.tab) {
                viewModel.cycleModel()
                return .handled
            }
        #endif
            .task {
                let isPro = await entitlement.refreshAndGetIsPro()
                showPremiumModelAlert = !viewModel.canUseSelectedModel(isPro: isPro)
            }
            .onAppear {
                onStreamingChanged?(viewModel.isStreaming)
                onStopHandlerReady? {
                    viewModel.stopStreaming()
                }
            }
            .onChange(of: viewModel.isStreaming) {
                onStreamingChanged?(viewModel.isStreaming)
            }
            .onChange(of: entitlement.isPro) { _, isPro in
                if isPro {
                    showPremiumModelAlert = false
                    showModelChooser = false
                } else if !canUseSelectedModel {
                    showPremiumModelAlert = true
                }
            }
            .onChange(of: viewModel.model.id) {
                showPremiumModelAlert = !canUseSelectedModel
                if canUseSelectedModel {
                    showModelChooser = false
                }
            }
            .onChange(of: viewModel.requiresPremiumAccess) {
                if viewModel.requiresPremiumAccess {
                    showPremiumModelAlert = true
                }
            }
            .alert("Premium Model Unavailable", isPresented: $showPremiumModelAlert) {
                if !freeModels.isEmpty {
                    Button("Change Model") {
                        showModelChooser = true
                    }
                }
                if onPremiumRequired != nil {
                    Button("View Subscription") {
                        onPremiumRequired?()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your selected model requires Premium. Choose a free model or renew your subscription.")
            }
            .confirmationDialog("Choose Model", isPresented: $showModelChooser, titleVisibility: .visible) {
                ForEach(freeModels) { model in
                    Button(model.displayName) {
                        viewModel.model = model
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    private var inputBar: some View {
        ConversationInputBar(
            text: $viewModel.inputText,
            selectedModel: $viewModel.model,
            isStreaming: viewModel.isStreaming,
            canSend: viewModel.canSend,
            availableModels: viewModel.availableModels,
            images: viewModel.attachedImages,
            onRemoveImage: { id in viewModel.removeImage(id: id) },
            onAddImages: { platformImages in
                for image in platformImages {
                    #if os(macOS)
                        if let attachment = ImageAttachment.from(nsImage: image) {
                            viewModel.addImage(attachment)
                        }
                    #else
                        if let attachment = ImageAttachment.from(uiImage: image) {
                            viewModel.addImage(attachment)
                        }
                    #endif
                }
            },
            onRequiresPro: onPremiumRequired,
            placeholder: inputPlaceholder,
            focusOnAppear: focusInputOnAppear,
            onSend: { viewModel.send() },
            onStop: { viewModel.stopStreaming() }
        )
        .background(conversationBackground)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [.clear, conversationBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 52)
            .offset(y: -52)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if let onBack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(colors.accent)
                }
                .buttonStyle(.plain)
            }

            Text(viewModel.action.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(colors.textPrimary)
                .lineLimit(1)

            Spacer()

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(colors.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Message List

    @State private var lastScrollTime = Date.distantPast

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.messages) { message in
                        MessageBubbleView(message: message)
                            .id(message.id)
                    }

                    if viewModel.isStreaming {
                        StreamingBubbleView(
                            reasoningText: viewModel.streamingReasoningText,
                            text: viewModel.streamingText,
                            reasoningSource: viewModel.reasoningMarkdownStreamSource,
                            source: viewModel.markdownStreamSource
                        )
                        .id("streaming")
                    }

                    #if os(iOS)
                        Color.clear
                            .frame(height: 1)
                            .id("conversation-frontier")
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.frame(in: .scrollView).minY
                            } action: { _, frontierY in
                                followStreamingIfNeeded(proxy: proxy, frontierY: frontierY)
                            }

                        if viewModel.isStreaming {
                            Color.clear
                                .containerRelativeFrame(.vertical)
                                .allowsHitTesting(false)
                        }
                    #endif
                }
                .padding(.horizontal, messageHorizontalPadding)
                .padding(.top, 20)
                .padding(.bottom, 44)
            }
            #if os(iOS)
            .scrollIndicators(.hidden)
            .transaction {
                $0.scrollContentOffsetAdjustmentBehavior = .disabled
            }
            .onGeometryChange(for: CGFloat.self) { geometry in
                geometry.size.height
            } action: { previousHeight, viewportHeight in
                conversationViewportHeight = viewportHeight
                if ConversationScrollPolicy.shouldReanchorForViewportChange(
                    previousHeight: previousHeight,
                    viewportHeight: viewportHeight,
                    isStreaming: viewModel.isStreaming,
                    isAutoFollowing: isAutoFollowingStreaming
                ) {
                    scrollToConversationFrontier(proxy: proxy)
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting {
                    isAutoFollowingStreaming = false
                } else if phase == .idle, viewModel.isStreaming {
                    isAutoFollowingStreaming = ConversationScrollPolicy.shouldResume(
                        frontierY: conversationFrontierY,
                        viewportHeight: conversationViewportHeight
                    )
                }
            }
            #endif
            .onChange(of: viewModel.messages.count) {
                #if os(iOS)
                    if viewModel.messages.last?.role == "user" {
                        scrollToLatestUserMessage(proxy: proxy)
                    } else if isAutoFollowingStreaming {
                        scrollToConversationFrontier(proxy: proxy)
                    }
                #else
                    scrollToBottom(proxy: proxy)
                #endif
            }
            .onChange(of: viewModel.streamingText) { _, _ in
                #if os(macOS)
                    let now = Date()
                    guard now.timeIntervalSince(lastScrollTime) >= 0.2 else { return }
                    lastScrollTime = now
                    scrollToBottom(proxy: proxy)
                #endif
            }
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(colors.error)
            Text(message)
                .font(.system(size: 13))
                .foregroundColor(colors.error)
                .lineLimit(2)
            Spacer()
            Button {
                viewModel.errorMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(colors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(colors.error.opacity(0.1))
    }
}

#if os(iOS) || os(macOS)
    private extension ConversationContentView {
        #if os(iOS)
            func scrollToLatestUserMessage(proxy: ScrollViewProxy) {
                guard let lastMessage = viewModel.messages.last, lastMessage.role == "user" else { return }
                isAutoFollowingStreaming = true
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastMessage.id, anchor: UnitPoint(x: 0.5, y: 0.08))
                }
            }

            func followStreamingIfNeeded(proxy: ScrollViewProxy, frontierY: CGFloat) {
                conversationFrontierY = frontierY
                guard viewModel.isStreaming,
                      ConversationScrollPolicy.shouldFollow(
                          frontierY: frontierY,
                          viewportHeight: conversationViewportHeight,
                          isAutoFollowing: isAutoFollowingStreaming
                      )
                else { return }

                let now = Date()
                guard now.timeIntervalSince(lastScrollTime) >= ConversationScrollPolicy.minimumScrollInterval else {
                    return
                }
                lastScrollTime = now

                scrollToConversationFrontier(proxy: proxy)
            }

            func scrollToConversationFrontier(proxy: ScrollViewProxy) {
                withAnimation(.easeOut(duration: ConversationScrollPolicy.scrollAnimationDuration)) {
                    proxy.scrollTo(
                        "conversation-frontier",
                        anchor: UnitPoint(x: 0.5, y: ConversationScrollPolicy.followViewportFraction)
                    )
                }
            }
        #endif

        #if os(macOS)
            func scrollToBottom(proxy: ScrollViewProxy) {
                withAnimation(.easeOut(duration: 0.2)) {
                    if viewModel.isStreaming {
                        proxy.scrollTo("streaming", anchor: .bottom)
                    } else if let lastMessage = viewModel.messages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        #endif
    }
#endif

#if os(iOS)
    enum ConversationScrollPolicy {
        static let followViewportFraction: CGFloat = 0.65
        static let resumeViewportFraction: CGFloat = 0.85
        static let minimumScrollInterval: TimeInterval = 0.12
        static let scrollAnimationDuration: TimeInterval = 0.12

        static func shouldFollow(
            frontierY: CGFloat,
            viewportHeight: CGFloat,
            isAutoFollowing: Bool
        ) -> Bool {
            isAutoFollowing &&
                viewportHeight > 0 &&
                frontierY > viewportHeight * followViewportFraction
        }

        static func shouldResume(frontierY: CGFloat, viewportHeight: CGFloat) -> Bool {
            viewportHeight > 0 &&
                frontierY >= 0 &&
                frontierY <= viewportHeight * resumeViewportFraction
        }

        static func shouldReanchorForViewportChange(
            previousHeight: CGFloat,
            viewportHeight: CGFloat,
            isStreaming: Bool,
            isAutoFollowing: Bool
        ) -> Bool {
            isStreaming &&
                isAutoFollowing &&
                previousHeight > 0 &&
                viewportHeight > 0 &&
                viewportHeight < previousHeight
        }
    }
#endif

// MARK: - Sheet Wrapper

/// Conversation view presented as a sheet (iOS).
/// Users dismiss by dragging the sheet down.
public struct ConversationView: View {
    private let session: ConversationSession
    private let onPremiumRequired: (() -> Void)?

    public init(session: ConversationSession, onPremiumRequired: (() -> Void)? = nil) {
        self.session = session
        self.onPremiumRequired = onPremiumRequired
    }

    public var body: some View {
        ConversationContentView(session: session, onPremiumRequired: onPremiumRequired)
    }
}
