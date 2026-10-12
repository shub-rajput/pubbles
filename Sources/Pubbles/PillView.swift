import SwiftUI

struct PillView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    @ObservedObject private var configManager = ConfigManager.shared
    @State private var cursorVisible = true

    private let blinkPublisher = Timer.publish(every: 0.53, on: .main, in: .common).autoconnect()

    private var style: StyleConfig { configManager.config.style }
    private var scale: CGFloat { style.pillScale }

    private static let weightOrder: [Font.Weight] = [
        .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
    ]

    private var cursorWeight: Font.Weight {
        guard let idx = Self.weightOrder.firstIndex(of: style.fontWeightValue), idx > 0 else {
            return .ultraLight
        }
        return Self.weightOrder[idx - 1]
    }

    private var scaledFontSize: CGFloat { style.fontSize * scale }

    // Recording badge sizing. Kept small and tucked into the top-leading corner so it
    // stays out of the way of the text. Its footprint is reserved in the text wrap width
    // (see micReservedWidth) so text never overflows the pill.
    private var micSize: CGFloat { scaledFontSize * 0.6 }
    private var micLeadingPad: CGFloat { style.paddingH * scale * 0.6 }
    private var micReservedWidth: CGFloat {
        viewModel.recordingBadgeVisible ? micSize + micLeadingPad : 0
    }

    private var cursorFont: Font {
        if style.fontFamily == "system" {
            return .system(size: scaledFontSize, weight: cursorWeight)
        }
        return .custom(style.fontFamily, size: scaledFontSize)
    }

    @ViewBuilder
    private var currentLineContent: some View {
        if viewModel.isPlaceholder {
            Text(viewModel.displayText)
                .font(style.textFont)
                .foregroundStyle(style.txtColor.opacity(0.7))
        } else if viewModel.animatedChars.isEmpty && viewModel.text.isEmpty {
            Text(cursorVisible ? "|" : " ")
                .font(cursorFont)
                .foregroundStyle(style.txtColor)
        } else if !viewModel.animatedChars.isEmpty {
            let editID = viewModel.editingCharID
            ForEach(viewModel.animatedChars) { ac in
                if ac.character == "\n" {
                    Color.clear.frame(width: 0, height: scaledFontSize)
                        .layoutValue(key: LineBreakKey.self, value: true)
                        .anchorPreference(key: EditCursorAnchorKey.self, value: .center) {
                            ac.id == editID ? $0 : nil
                        }
                } else {
                    Text(ac.character)
                        .font(style.textFont)
                        .foregroundStyle(style.txtColor)
                        .transition(CharTransition())
                        .anchorPreference(key: EditCursorAnchorKey.self, value: .leading) {
                            ac.id == editID ? $0 : nil
                        }
                        .layoutValue(key: IsWhitespaceKey.self, value: ac.character == " ")
                }
            }
            // End-of-line cursor: visible only when cursor is at end
            let isCursorChar = cursorVisible && viewModel.isActive && editID == nil
            Text(isCursorChar ? "|" : " ")
                .font(cursorFont)
                .foregroundStyle(style.txtColor)
                .layoutValue(key: IsWhitespaceKey.self, value: !isCursorChar)
        } else {
            // Fallback for non-animated text (hints, etc.)
            Text(viewModel.text).font(style.textFont).foregroundStyle(style.txtColor) + Text(cursorVisible && viewModel.isActive ? "|" : " ").font(cursorFont).foregroundStyle(style.txtColor)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Recording badge — live pill only. Pinned bubbles use PinnedPillView, so they
            // never show this. Pulses via opacity (not scale) so it doesn't reflow text, and
            // top-aligned so it stays tucked in the corner on multi-line bubbles.
            if viewModel.recordingBadgeVisible {
                Image(systemName: "mic.fill")
                    .font(.system(size: micSize))
                    .foregroundStyle(style.txtColor)
                    .opacity(0.25 + Double(viewModel.audioLevel) * 0.75)
                    .animation(.easeOut(duration: 0.1), value: viewModel.audioLevel)
                    .padding(.leading, micLeadingPad)
                    .padding(.top, style.paddingV * scale)
            }
            VStack(alignment: .leading, spacing: 0) {
            // Previous line
            if viewModel.showPreviousLine {
                HStack(spacing: 0) {
                    if !viewModel.previousLineChars.isEmpty {
                        ForEach(viewModel.previousLineChars) { ac in
                            Text(ac.character)
                                .font(style.textFont)
                                .foregroundStyle(style.txtColor.opacity(0.6))
                        }
                    } else {
                        Text(viewModel.previousLine)
                            .font(style.textFont)
                            .foregroundStyle(style.txtColor.opacity(0.6))
                    }
                }
                .padding(.horizontal, style.paddingH * scale)
                .padding(.top, style.paddingV * scale)
                .padding(.bottom, style.paddingV * scale / 2)
                .transition(.identity)
            }

            // Current line (or placeholder)
            Group {
                if configManager.config.behavior.multiLine {
                    CharFlowLayout(contentMaxWidth: (style.maxWidth - 2 * style.paddingH) * scale - micReservedWidth) {
                        currentLineContent
                    }
                } else {
                    HStack(spacing: 0) {
                        currentLineContent
                    }
                }
            }
            .padding(.horizontal, style.paddingH * scale)
            .padding(.top, viewModel.showPreviousLine ? style.paddingV * scale / 2 : style.paddingV * scale)
            .padding(.bottom, style.paddingV * scale)
            .overlayPreferenceValue(EditCursorAnchorKey.self) { anchor in
                if let anchor, viewModel.isActive {
                    GeometryReader { proxy in
                        let pt = proxy[anchor]
                        Text(cursorVisible ? "|" : " ")
                            .font(cursorFont)
                            .foregroundStyle(style.txtColor)
                            .fixedSize()
                            .position(x: pt.x, y: pt.y)
                    }
                }
            }
            }
        }
        .frame(maxWidth: style.maxWidth * scale, alignment: .leading)
        .fixedSize()
        .background {
            if !style.glassEffect {
                style.pillBackground
            }
        }
        .clipShape(style.pillShape)
        .modifier(GlassEffectModifier(
            enabled: style.glassEffect,
            tint: style.bgColor.opacity(style.backgroundOpacity),
            shape: style.pillShape
        ))
        .shadow(
            color: (Color(hex: style.shadowColor) ?? .black)
                .opacity(style.shadowOpacity),
            radius: style.shadowRadius * scale,
            x: style.shadowX * scale,
            y: style.shadowY * scale
        )
        .overlay(
            style.pillShape
                .strokeBorder(
                    (Color(hex: style.borderColor) ?? .white)
                        .opacity(style.borderOpacity),
                    lineWidth: style.borderWidth * scale
                )
        )
        .onReceive(blinkPublisher) { _ in cursorVisible.toggle() }
        .onChange(of: viewModel.textCursorIndex) { _, _ in cursorVisible = true }
    }
}

struct LineBreakKey: LayoutValueKey {
    static let defaultValue: Bool = false
}

struct IsWhitespaceKey: LayoutValueKey {
    static let defaultValue: Bool = false
}

struct CharFlowLayout: Layout {
    var contentMaxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let singleLine = layout(subviews: subviews, availableWidth: .infinity).size
        if singleLine.width <= contentMaxWidth {
            return singleLine
        } else {
            return layout(subviews: subviews, availableWidth: contentMaxWidth).size
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let singleLineWidth = layout(subviews: subviews, availableWidth: .infinity).size.width
        let wrapWidth: CGFloat = singleLineWidth <= contentMaxWidth ? .infinity : contentMaxWidth
        let frames = layout(subviews: subviews, availableWidth: wrapWidth).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func layout(subviews: Subviews, availableWidth: CGFloat) -> (size: CGSize, frames: [CGRect]) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var atLineStart = true
        var prevWasSpace = true

        for (i, subview) in subviews.enumerated() {
            let size = sizes[i]

            if subview[LineBreakKey.self] {
                frames.append(CGRect(x: x, y: y, width: 0, height: 0))
                x = 0; y += lineHeight + 4; lineHeight = 0; atLineStart = true; prevWasSpace = true
                continue
            }

            let isSpace = subview[IsWhitespaceKey.self]

            // Skip leading whitespace at the start of any line (prevents indent after wrap)
            if atLineStart && isSpace {
                frames.append(CGRect(x: 0, y: y, width: 0, height: 0))
                prevWasSpace = true
                continue
            }

            // Word-wrap: at the start of a word, check if the whole word fits on this line
            if !isSpace && prevWasSpace && !atLineStart {
                var wordWidth: CGFloat = 0
                var j = i
                while j < subviews.count && !subviews[j][IsWhitespaceKey.self] && !subviews[j][LineBreakKey.self] {
                    wordWidth += sizes[j].width
                    j += 1
                }
                if x + wordWidth > availableWidth && wordWidth <= availableWidth {
                    x = 0; y += lineHeight + 4; lineHeight = 0; atLineStart = true
                }
            }

            if x + size.width > availableWidth && x > 0 {
                x = 0; y += lineHeight + 4; lineHeight = 0; atLineStart = true
            }

            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width
            lineHeight = max(lineHeight, size.height)
            totalWidth = max(totalWidth, x)
            atLineStart = false
            prevWasSpace = isSpace
        }

        return (CGSize(width: totalWidth, height: y + lineHeight), frames)
    }
}

private struct EditCursorAnchorKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: Anchor<CGPoint>?
    static func reduce(value: inout Anchor<CGPoint>?, nextValue: () -> Anchor<CGPoint>?) {
        value = value ?? nextValue()
    }
}

private struct CharTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        let offsetY: CGFloat = switch phase {
        case .willAppear: 6
        case .identity: 0
        case .didDisappear: -6
        }
        content
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: offsetY)
            .scaleEffect(phase.isIdentity ? 1 : 0.88)
            .blur(radius: phase.isIdentity ? 0 : 4)
    }
}

struct GlassEffectModifier: ViewModifier {
    let enabled: Bool
    let tint: Color
    let shape: UnevenRoundedRectangle

    func body(content: Content) -> some View {
        if enabled, #available(macOS 26.0, *) {
            content.glassEffect(.regular.tint(tint), in: shape)
        } else {
            content
        }
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        guard hexSanitized.count == 6, let hexNumber = UInt64(hexSanitized, radix: 16) else { return nil }
        let r = Double((hexNumber & 0xFF0000) >> 16) / 255
        let g = Double((hexNumber & 0x00FF00) >> 8) / 255
        let b = Double(hexNumber & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Shared pill style helpers
// Used by both PillView and PinnedPillView to avoid duplication.

extension StyleConfig {
    static let weightMap: [String: Font.Weight] = [
        "ultraLight": .ultraLight, "thin": .thin, "light": .light,
        "regular": .regular, "medium": .medium, "semibold": .semibold,
        "bold": .bold, "heavy": .heavy, "black": .black,
    ]

    var fontWeightValue: Font.Weight { Self.weightMap[fontWeight] ?? .medium }

    var bgColor: Color { Color(hex: backgroundColor) ?? .green }
    var txtColor: Color { Color(hex: textColor) ?? .white }

    var swiftUIMaterial: Material {
        switch vibrancy {
        case "ultraThin": return .ultraThinMaterial
        case "thin": return .thinMaterial
        case "regular": return .regularMaterial
        case "thick": return .thickMaterial
        case "ultraThick": return .ultraThickMaterial
        default: return .ultraThinMaterial
        }
    }

    @ViewBuilder
    var pillBackground: some View {
        if vibrancy != nil {
            Rectangle().fill(swiftUIMaterial)
                .overlay(bgColor.opacity(backgroundOpacity))
        } else if let gradientColors = backgroundGradient, gradientColors.count >= 2 {
            LinearGradient(
                colors: gradientColors.compactMap { Color(hex: $0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(backgroundOpacity)
        } else {
            bgColor.opacity(backgroundOpacity)
        }
    }

    var pillShape: UnevenRoundedRectangle {
        let r = cornerRadius * pillScale
        return UnevenRoundedRectangle(
            topLeadingRadius: pointerCorner ? 2 * pillScale : r,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: r,
            style: .continuous
        )
    }

    var textFont: Font {
        if fontFamily == "system" {
            return .system(size: fontSize * pillScale, weight: fontWeightValue)
        }
        return .custom(fontFamily, size: fontSize * pillScale)
    }
}
