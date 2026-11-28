//
//  OnboardingReceiptViews.swift
//  TLingo
//

#if os(iOS)
    import SwiftUI

    struct OnboardingPaperPalette {
        let colorScheme: ColorScheme

        static let ink = Color(rgb: 0x2A2622)
        static let inkSecondary = Color(rgb: 0x6B6258)
        static let rule = Color(rgb: 0xB5AA9C)
        static let accent = Color(rgb: 0xD9622B)
        static let accentDeep = Color(rgb: 0xC95A1D)
        static let success = Color(rgb: 0x3F7A2E)

        private var isDark: Bool { colorScheme == .dark }

        var background: LinearGradient {
            LinearGradient(
                colors: isDark
                    ? [Color(rgb: 0x1A1612), Color(rgb: 0x121010)]
                    : [Color(rgb: 0xF7F3EC), Color(rgb: 0xEFE9DF)],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        var solidBackground: Color { isDark ? Color(rgb: 0x121010) : Color(rgb: 0xEFE9DF) }
        var paper: Color { isDark ? Color(rgb: 0xEBE4D6) : Color(rgb: 0xFBF8F1) }
        var title: Color { isDark ? .white : Color(rgb: 0x1C1C22) }
        var subtitle: Color { isDark ? .white.opacity(0.65) : .black.opacity(0.6) }
        var buttonFill: Color { isDark ? Color(rgb: 0xF3ECE3) : Self.ink }
        var buttonText: Color { isDark ? Color(rgb: 0x1C1C22) : .white }
        var disabledButtonFill: Color { isDark ? .white.opacity(0.28) : Self.ink.opacity(0.28) }
        var secondaryText: Color { isDark ? .white.opacity(0.85) : Self.ink }
        var dotActive: Color { isDark ? Color(rgb: 0xF3ECE3) : Self.ink }
        var dotInactive: Color { isDark ? .white.opacity(0.25) : .black.opacity(0.25) }
        var shadow: Color { isDark ? .black.opacity(0.5) : Color(rgb: 0x503214).opacity(0.14) }

        var typewriterBody: LinearGradient {
            LinearGradient(
                stops: isDark
                    ? [.init(color: Color(rgb: 0xD4733A), location: 0), .init(color: Color(rgb: 0xC25E26), location: 0.55),
                       .init(color: Color(rgb: 0xA14A18), location: 1)]
                    : [.init(color: Color(rgb: 0xF08A4B), location: 0), .init(color: Color(rgb: 0xE46F2E), location: 0.55),
                       .init(color: Color(rgb: 0xC95A1D), location: 1)],
                startPoint: .top,
                endPoint: .bottom
            )
        }

        var typewriterShadow: Color { isDark ? .black.opacity(0.55) : Color(rgb: 0x964614).opacity(0.25) }
    }

    extension Color {
        init(rgb: UInt32) {
            self.init(
                .sRGB,
                red: Double((rgb >> 16) & 0xFF) / 255,
                green: Double((rgb >> 8) & 0xFF) / 255,
                blue: Double(rgb & 0xFF) / 255,
                opacity: 1
            )
        }
    }

    // MARK: - Receipt

    /// Paper with scalloped tear-off edges, like a till receipt.
    struct ReceiptShape: Shape {
        var scallopTop = true
        var scallopBottom = true

        static let edgeHeight: CGFloat = 8
        private static let period: CGFloat = 12
        private static let radius: CGFloat = 5

        func path(in rect: CGRect) -> Path {
            let period = Self.period
            let radius = Self.radius
            let count = Int((rect.width / period).rounded(.up))
            let samples = 8
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            if scallopTop {
                for index in 0 ..< count {
                    let centerX = rect.minX + period / 2 + CGFloat(index) * period
                    for sample in 0 ... samples {
                        let angle = Double.pi - Double.pi * Double(sample) / Double(samples)
                        let x = min(rect.maxX, centerX + radius * CGFloat(cos(angle)))
                        path.addLine(to: CGPoint(x: x, y: rect.minY + radius * CGFloat(sin(angle))))
                    }
                }
            }
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            if scallopBottom {
                for index in (0 ..< count).reversed() {
                    let centerX = rect.minX + period / 2 + CGFloat(index) * period
                    for sample in 0 ... samples {
                        let angle = Double.pi * Double(sample) / Double(samples)
                        let x = max(rect.minX, min(rect.maxX, centerX + radius * CGFloat(cos(angle))))
                        path.addLine(to: CGPoint(x: x, y: rect.maxY - radius * CGFloat(sin(angle))))
                    }
                }
            }
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
            return path
        }
    }

    struct ReceiptPaper<Content: View>: View {
        let width: CGFloat
        var spacing: CGFloat = 12
        var insets = EdgeInsets(top: 14, leading: 18, bottom: 18, trailing: 18)
        var scallopBottom = true
        var minHeight: CGFloat?
        @ViewBuilder let content: () -> Content

        @Environment(\.colorScheme) private var colorScheme

        var body: some View {
            let palette = OnboardingPaperPalette(colorScheme: colorScheme)
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .font(.system(size: 13, design: .monospaced))
            .foregroundStyle(OnboardingPaperPalette.ink)
            .padding(.top, insets.top + ReceiptShape.edgeHeight)
            .padding(.bottom, insets.bottom + (scallopBottom ? ReceiptShape.edgeHeight : 0))
            .padding(.leading, insets.leading)
            .padding(.trailing, insets.trailing)
            .frame(width: width, alignment: .leading)
            .frame(minHeight: minHeight, alignment: .top)
            .background(
                ReceiptShape(scallopBottom: scallopBottom)
                    .fill(palette.paper)
                    .shadow(color: palette.shadow, radius: 7, x: 0, y: 6)
            )
            .environment(\.colorScheme, .light)
        }
    }

    struct ReceiptRule: View {
        var body: some View {
            Line()
                .stroke(OnboardingPaperPalette.rule, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(height: 1)
                .accessibilityHidden(true)
        }

        private struct Line: Shape {
            func path(in rect: CGRect) -> Path {
                var path = Path()
                path.move(to: CGPoint(x: rect.minX, y: rect.midY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
                return path
            }
        }
    }

    struct ReceiptHeader<Leading: View, Trailing: View>: View {
        let number: Int
        @ViewBuilder var leading: () -> Leading
        @ViewBuilder var trailing: () -> Trailing

        var body: some View {
            HStack(spacing: 6) {
                leading()
                Spacer(minLength: 0)
                trailing()
                Text(verbatim: String(format: "No. %03d", number))
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(OnboardingPaperPalette.inkSecondary)
            .frame(minHeight: 16)
        }
    }

    extension ReceiptHeader where Trailing == EmptyView {
        init(number: Int, @ViewBuilder leading: @escaping () -> Leading) {
            self.init(number: number, leading: leading, trailing: { EmptyView() })
        }
    }

    extension ReceiptHeader where Leading == EmptyView, Trailing == EmptyView {
        init(number: Int) {
            self.init(number: number, leading: { EmptyView() }, trailing: { EmptyView() })
        }
    }

    /// Rotated outline label that slaps onto the receipt when something lands.
    struct ReceiptStamp: View {
        let title: LocalizedStringKey

        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var landed = false

        var body: some View {
            Text(title)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(0.9)
                .foregroundStyle(OnboardingPaperPalette.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(rgb: 0xFBF8F1).opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(OnboardingPaperPalette.accent, lineWidth: 2)
                )
                .rotationEffect(.degrees(-8))
                .scaleEffect(landed || reduceMotion ? 1 : 1.6)
                .opacity(landed || reduceMotion ? 1 : 0)
                .onAppear {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) {
                        landed = true
                    }
                }
                .sensoryFeedback(.success, trigger: landed)
        }
    }

    // MARK: - Typewriter

    /// Intro hero: a typewriter feeding a receipt that types out a translation.
    struct TypewriterHero: View {
        static let size = CGSize(width: 340, height: 450)

        private static let cycle: TimeInterval = 4.6
        private static let typedText = "Hi, how are you?"

        @Environment(\.colorScheme) private var colorScheme
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            if reduceMotion {
                scene(progress: 1, time: 0)
            } else {
                TimelineView(.animation) { context in
                    let time = context.date.timeIntervalSinceReferenceDate
                    scene(progress: time.truncatingRemainder(dividingBy: Self.cycle) / Self.cycle, time: time)
                }
            }
        }

        private func scene(progress: Double, time: TimeInterval) -> some View {
            let palette = OnboardingPaperPalette(colorScheme: colorScheme)
            let typingProgress = min(max((progress - 0.35) / 0.5, 0), 1)
            let typedCount = Int((typingProgress * Double(Self.typedText.count)).rounded(.down))
            let feedProgress = min(max((progress - 0.15) / 0.85, 0), 1)
            let feedOffset = 150 * (1 - Self.easeOut(feedProgress))
            let caretVisible = reduceMotion || time.truncatingRemainder(dividingBy: 0.6) < 0.3
            let strikeDown = !reduceMotion && sin(time / 0.26 * 2 * .pi) > 0
            let lcdSteps = reduceMotion ? 10 : 1 + Int(typingProgress * 9)

            return VStack(spacing: 0) {
                VStack(spacing: 0) {
                    paperWindow(palette: palette, typedCount: typedCount, caretVisible: caretVisible, feedOffset: feedOffset)
                    platen
                        .padding(.top, -Self.paperTuck)
                }
                .offset(x: -24 * CGFloat(typedCount) / CGFloat(Self.typedText.count))
                .zIndex(2)
                body(palette: palette, strikeDown: strikeDown, lcdSteps: lcdSteps)
                    .padding(.top, -4)
                    .zIndex(1)
                feet
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .bottom)
            .environment(\.colorScheme, .light)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("A typewriter types the English translation of a Spanish greeting."))
        }

        private static let paperWindowHeight: CGFloat = 282
        private static let paperTuck: CGFloat = 16

        private static func easeOut(_ value: Double) -> Double {
            1 - pow(1 - value, 3)
        }

        private func paperWindow(
            palette: OnboardingPaperPalette,
            typedCount: Int,
            caretVisible: Bool,
            feedOffset: CGFloat
        ) -> some View {
            ReceiptPaper(
                width: 260,
                spacing: 11,
                insets: EdgeInsets(top: 14, leading: 20, bottom: 18, trailing: 20),
                scallopBottom: false,
                minHeight: Self.paperWindowHeight
            ) {
                HStack(spacing: 10) {
                    Text(verbatim: "TL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(palette.paper)
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(OnboardingPaperPalette.ink))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: "TLINGO")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .tracking(1.5)
                        Text("Translate anywhere")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(OnboardingPaperPalette.inkSecondary)
                    }
                }
                ReceiptRule()
                HStack {
                    Text(verbatim: "Español → English")
                    Spacer(minLength: 0)
                    Text(verbatim: "No. 001")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(OnboardingPaperPalette.inkSecondary)
                Text(verbatim: "Hola, ¿cómo estás?")
                    .foregroundStyle(OnboardingPaperPalette.inkSecondary)
                HStack(spacing: 1) {
                    Text(verbatim: String(Self.typedText.prefix(typedCount)))
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .fixedSize()
                    Rectangle()
                        .fill(OnboardingPaperPalette.accent)
                        .frame(width: 2, height: 22)
                        .opacity(caretVisible ? 1 : 0)
                }
                .frame(height: 26)
                ReceiptRule()
                HStack {
                    Text("Text menu · Translate")
                    Spacer(minLength: 0)
                    Text(verbatim: "0.4s")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(OnboardingPaperPalette.inkSecondary)
            }
            .offset(y: feedOffset)
            .frame(width: 260, height: Self.paperWindowHeight, alignment: .bottom)
            .clipped()
        }

        private var platen: some View {
            HStack(spacing: 0) {
                knob
                Capsule()
                    .fill(LinearGradient(
                        stops: [
                            .init(color: Color(rgb: 0x4A3F37), location: 0),
                            .init(color: Color(rgb: 0x211C18), location: 0.55),
                            .init(color: Color(rgb: 0x3A312A), location: 1),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ))
                    .frame(height: 22)
                knob
            }
            .frame(width: 300, height: 30)
        }

        private var knob: some View {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(LinearGradient(colors: [Color(rgb: 0x5A4A3E), Color(rgb: 0x2E2620)], startPoint: .top, endPoint: .bottom))
                .frame(width: 16, height: 26)
        }

        private func body(palette: OnboardingPaperPalette, strikeDown: Bool, lcdSteps: Int) -> some View {
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: 26,
                bottomLeadingRadius: 32,
                bottomTrailingRadius: 32,
                topTrailingRadius: 26,
                style: .continuous
            )
            return VStack(spacing: 10) {
                HStack {
                    Text(verbatim: "TL-26 TYPEWRITER")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.4)
                    Spacer()
                    Circle().fill(Color(rgb: 0x6A2E10)).frame(width: 7, height: 7)
                }
                .foregroundStyle(Color(rgb: 0x3C1905).opacity(0.55))

                HStack(alignment: .center, spacing: 12) {
                    lcd(steps: lcdSteps)
                    VStack(spacing: 6) {
                        keyRow("QWERTY", strikeIndex: 2, strikeDown: strikeDown)
                        keyRow("ASDFGH", strikeIndex: nil, strikeDown: false)
                    }
                }

                Capsule()
                    .fill(LinearGradient(colors: [Color(rgb: 0xFFFDF8), Color(rgb: 0xE6DCCB)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 170, height: 14)
                    .background(Capsule().fill(Color(rgb: 0x9C4415)).offset(y: 3))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .frame(width: 340, height: 160)
            .background(
                shape
                    .fill(palette.typewriterBody)
                    .overlay(alignment: .top) {
                        shape.stroke(.white.opacity(0.4), lineWidth: 2).mask(alignment: .top) {
                            Rectangle().frame(height: 6)
                        }
                    }
                    .shadow(color: palette.typewriterShadow, radius: 15, x: 0, y: 18)
            )
        }

        private func lcd(steps: Int) -> some View {
            VStack(alignment: .leading) {
                Text(verbatim: "TYPING")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    ForEach(0 ..< 10, id: \.self) { index in
                        Rectangle()
                            .fill(Color(rgb: 0x2E3326).opacity(index < steps ? 1 : 0.15))
                            .frame(width: 6, height: 10)
                    }
                }
            }
            .foregroundStyle(Color(rgb: 0x2E3326))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(width: 104, height: 58, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(rgb: 0xD9DDC6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color(rgb: 0xB95020).opacity(0.32), lineWidth: 3)
                    )
            )
        }

        private func keyRow(_ letters: String, strikeIndex: Int?, strikeDown: Bool) -> some View {
            HStack(spacing: 0) {
                ForEach(Array(letters.enumerated()), id: \.offset) { index, letter in
                    TypewriterKeyCap(letter: String(letter), isDown: index == strikeIndex && strikeDown)
                        .frame(maxWidth: .infinity)
                }
            }
        }

        private var feet: some View {
            HStack {
                foot
                Spacer()
                foot
            }
            .frame(width: 280)
            .padding(.top, -2)
        }

        private var foot: some View {
            UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6)
                .fill(Color(rgb: 0x3A2A20))
                .frame(width: 48, height: 8)
        }
    }

    private struct TypewriterKeyCap: View {
        let letter: String
        let isDown: Bool

        var body: some View {
            Text(verbatim: letter)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(rgb: 0x3A302A))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(RadialGradient(
                        colors: [Color(rgb: 0xFFFDF8), Color(rgb: 0xECE4D6)],
                        center: UnitPoint(x: 0.5, y: 0.35),
                        startRadius: 0,
                        endRadius: 11
                    ))
                )
                .background(Circle().fill(Color(rgb: 0x9C4415)).offset(y: isDown ? 1 : 3))
                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 4)
                .offset(y: isDown ? 2 : 0)
        }
    }

    // MARK: - Trial timeline

    struct TrialTimeline: View {
        let startDate: String
        let reminderDate: String?
        let renewDate: String
        let renewPrice: String

        var body: some View {
            HStack(alignment: .top, spacing: 0) {
                node(
                    symbol: "gift.fill",
                    fill: Color(rgb: 0xE46F2E),
                    stroke: nil,
                    iconColor: .white,
                    value: Text(verbatim: "$0"),
                    caption: startDate,
                    valueColor: OnboardingPaperPalette.ink
                )
                Spacer(minLength: 0)
                node(
                    symbol: "bell",
                    fill: reminderDate == nil ? Color(rgb: 0xFBF8F1) : OnboardingPaperPalette.ink,
                    stroke: reminderDate == nil ? OnboardingPaperPalette.rule : OnboardingPaperPalette.ink,
                    iconColor: reminderDate == nil ? OnboardingPaperPalette.rule : Color(rgb: 0xFBF8F1),
                    value: Text(verbatim: reminderDate ?? "—"),
                    caption: nil,
                    valueColor: reminderDate == nil ? OnboardingPaperPalette.rule : OnboardingPaperPalette.ink
                )
                Spacer(minLength: 0)
                node(
                    symbol: "arrow.triangle.2.circlepath",
                    fill: Color(rgb: 0xFBF8F1),
                    stroke: OnboardingPaperPalette.ink,
                    iconColor: OnboardingPaperPalette.ink,
                    value: Text(verbatim: renewPrice),
                    caption: renewDate,
                    valueColor: OnboardingPaperPalette.ink
                )
            }
            .background(alignment: .top) {
                ReceiptRule()
                    .padding(.horizontal, 20)
                    .padding(.top, 14)
            }
            .accessibilityElement(children: .combine)
        }

        private func node(
            symbol: String,
            fill: Color,
            stroke: Color?,
            iconColor: Color,
            value: Text,
            caption: String?,
            valueColor: Color
        ) -> some View {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(iconColor)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(fill))
                    .overlay {
                        if let stroke {
                            Circle().stroke(stroke, lineWidth: 1.6)
                        }
                    }
                value
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(valueColor)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.top, 4)
                Text(verbatim: caption ?? " ")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(OnboardingPaperPalette.inkSecondary)
            }
            .frame(minWidth: 44)
        }
    }
#endif
