import SwiftUI

struct DrawingCanvasView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    let lineColor: Color
    let lineWidth: CGFloat

    var body: some View {
        // TimelineView polls currentStroke at display refresh rate while drawing.
        // currentStroke is not @Published to avoid triggering PillView redraws on every drag point.
        TimelineView(.animation(paused: !viewModel.isDrawing)) { _ in
            Canvas { context, size in
                let allStrokes = viewModel.strokes + (viewModel.currentStroke.isEmpty ? [] : [viewModel.currentStroke])
                for stroke in allStrokes {
                    guard stroke.count >= 2 else { continue }
                    var path = Path()
                    path.move(to: CGPoint(x: stroke[0].x, y: stroke[0].y))
                    for i in 1..<stroke.count {
                        path.addLine(to: CGPoint(x: stroke[i].x, y: stroke[i].y))
                    }
                    context.stroke(path, with: .color(lineColor), style: StrokeStyle(
                        lineWidth: lineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    ))
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct PillContainerView: View {
    @ObservedObject var viewModel: SubtitleViewModel
    @ObservedObject private var configManager = ConfigManager.shared
    @State private var springScale: CGFloat = 1.0
    let screenID: ObjectIdentifier

    private var fadeIn: Double { configManager.config.behavior.fadeInDuration }
    private var fadeOut: Double { configManager.config.behavior.fadeOutDuration }
    private var lineColor: Color { Color(hex: configManager.config.style.drawingLineColor) ?? .red }
    private var lineWidth: CGFloat { configManager.config.style.drawingLineWidth }

    private var isActiveScreen: Bool {
        viewModel.activeScreenID == screenID
    }

    private var drawingActive: Bool {
        viewModel.isActive && viewModel.drawingModeEnabled && isActiveScreen
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // Drawing canvas (renders on active screen when strokes exist and pill is visible)
            if viewModel.isVisible && isActiveScreen && (!viewModel.strokes.isEmpty || viewModel.isDrawing) {
                DrawingCanvasView(viewModel: viewModel, lineColor: lineColor, lineWidth: lineWidth)
                    .transition(.opacity)
            }

            // Cursor dot indicator when drawing mode is active
            if drawingActive {
                Circle()
                    .fill(lineColor)
                    .frame(width: max(lineWidth * 2, 8), height: max(lineWidth * 2, 8))
                    .shadow(color: lineColor.opacity(0.5), radius: 3)
                    .position(x: viewModel.cursorPosition.x, y: viewModel.cursorPosition.y)
                    .allowsHitTesting(false)
            }

            // Pinned pills (static, screen-filtered)
            ForEach(viewModel.pinnedPills.filter { $0.screenID == screenID }) { pill in
                PinnedPillView(pill: pill)
                    .offset(
                        x: pill.position.x + configManager.config.style.cursorOffset.x,
                        y: pill.position.y + configManager.config.style.cursorOffset.y
                    )
                    .transition(.opacity)
            }

            if viewModel.ghostCursorActive && isActiveScreen {
                GhostCursorView()
                    .offset(x: viewModel.cursorPosition.x, y: viewModel.cursorPosition.y)
                    .allowsHitTesting(false)
            }

            if viewModel.isVisible && isActiveScreen && !viewModel.pillHiddenForDrawing {
                PillView(viewModel: viewModel)
                    .scaleEffect(springScale, anchor: .topLeading)
                    .onChange(of: configManager.config.style.pillScale) { oldVal, newVal in
                        guard newVal > 0 else { return }
                        springScale = oldVal / newVal
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                            springScale = 1.0
                        }
                    }
                    .offset(
                        x: viewModel.cursorPosition.x + configManager.config.style.cursorOffset.x,
                        y: viewModel.cursorPosition.y + configManager.config.style.cursorOffset.y
                    )
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .allowsHitTesting(drawingActive)
        .gesture(drawingGesture)
        .animation(viewModel.isVisible && isActiveScreen
            ? .smooth(duration: fadeIn)
            : .easeOut(duration: fadeOut),
            value: viewModel.isVisible && isActiveScreen
        )
        .animation(viewModel.pillHiddenForDrawing
            ? .easeOut(duration: fadeOut)
            : .smooth(duration: fadeIn),
            value: viewModel.pillHiddenForDrawing
        )
    }

}

/// The system arrow, drawn by Pubbles for an agent's ghost pointer. Offset so its hotspot sits on
/// the parent's offset point.
private struct GhostCursorView: View {
    private let cursor = NSCursor.arrow

    var body: some View {
        Image(nsImage: cursor.image)
            .offset(x: -cursor.hotSpot.x, y: -cursor.hotSpot.y)
    }
}

private struct PinnedPillView: View {
    let pill: PinnedPill
    @ObservedObject private var configManager = ConfigManager.shared
    @State private var appeared = false

    private var style: StyleConfig { configManager.config.style }
    private var scale: CGFloat { style.pillScale }
    private var pinnedBorderColor: Color { Color(hex: style.pinnedBorderColor) ?? .white }

    /// Backing shape for the sticker border — corner radii grow by borderWidth so the
    /// expanded outline stays concentric with the pill rather than looking too sharp.
    private var stickerShape: UnevenRoundedRectangle {
        let pad = style.pinnedBorderWidth * scale
        let r = style.cornerRadius * scale + pad
        return UnevenRoundedRectangle(
            topLeadingRadius: style.pointerCorner ? 2 * scale + pad : r,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: r,
            style: .continuous
        )
    }

    var body: some View {
        let textFont = style.textFont
        let txtColor = style.txtColor
        VStack(alignment: .leading, spacing: 0) {
            // Previous line (faded)
            if pill.showPreviousLine && !pill.previousLine.isEmpty {
                HStack(spacing: 0) {
                    ForEach(pill.previousLineChars) { ac in
                        Text(ac.character).font(textFont).foregroundStyle(txtColor.opacity(0.6))
                    }
                }
                .padding(.horizontal, style.paddingH * scale)
                .padding(.top, style.paddingV * scale)
                .padding(.bottom, style.paddingV * scale / 2)
            }

            // Main text
            Group {
                if configManager.config.behavior.multiLine {
                    CharFlowLayout(contentMaxWidth: (style.maxWidth - 2 * style.paddingH) * scale) {
                        ForEach(pill.chars) { ac in
                            if ac.character == "\n" {
                                Color.clear.frame(width: 0, height: 0)
                                    .layoutValue(key: LineBreakKey.self, value: true)
                            } else {
                                Text(ac.character)
                                    .font(textFont)
                                    .foregroundStyle(txtColor)
                                    .layoutValue(key: IsWhitespaceKey.self, value: ac.character == " ")
                            }
                        }
                    }
                } else {
                    HStack(spacing: 0) {
                        ForEach(pill.chars) { ac in
                            if ac.character != "\n" {
                                Text(ac.character)
                                    .font(textFont)
                                    .foregroundStyle(txtColor)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, style.paddingH * scale)
            .padding(.top, pill.showPreviousLine ? style.paddingV * scale / 2 : style.paddingV * scale)
            .padding(.bottom, style.paddingV * scale)
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
        // Sticker look: colored outer border + drop shadow (behind the pill)
        // Skipped when glass effect is active — the backing conflicts with the frosted look
        .background(
            Group {
                if !style.glassEffect && style.pinnedBorderWidth > 0 {
                    stickerShape
                        .fill(pinnedBorderColor)
                        .padding(-style.pinnedBorderWidth * scale)
                        .shadow(color: .black.opacity(0.45), radius: 0, x: 1 * scale, y: 2 * scale)
                }
            }
        )
        // Pin badge at top-center
        .overlay(alignment: .top) {
            Image(systemName: "pin.fill")
                .font(.system(size: style.pinIconSize * scale, weight: .heavy))
                .foregroundColor(Color(hex: style.pinIconColor) ?? .black)
                .rotationEffect(.degrees(45))
                // 8-direction 0-blur shadows = stroke matching pinned border color
                .shadow(color: pinnedBorderColor, radius: 0, x:  1, y:  0)
                .shadow(color: pinnedBorderColor, radius: 0, x: -1, y:  0)
                .shadow(color: pinnedBorderColor, radius: 0, x:  0, y:  1)
                .shadow(color: pinnedBorderColor, radius: 0, x:  0, y: -1)
                .shadow(color: pinnedBorderColor, radius: 0, x:  1, y:  1)
                .shadow(color: pinnedBorderColor, radius: 0, x: -1, y: -1)
                .shadow(color: pinnedBorderColor, radius: 0, x:  1, y: -1)
                .shadow(color: pinnedBorderColor, radius: 0, x: -1, y:  1)
                // drop shadow on top
                .shadow(color: .black.opacity(0.4), radius: 2, x: 1, y: 2)
            .scaleEffect(appeared ? 1 : 0.3)
            .offset(y: -15)
        }
        .scaleEffect(appeared ? 1 : 0.9)
        .onAppear {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.55)) {
                appeared = true
            }
        }
    }
}

private extension PillContainerView {
    var drawingGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = NSPoint(x: value.location.x, y: value.location.y)
                // Update cursor position so pill follows during drawing
                viewModel.cursorPosition = point
                if viewModel.currentStroke.isEmpty {
                    viewModel.startStroke(at: point)
                } else {
                    viewModel.continueStroke(to: point)
                }
            }
            .onEnded { _ in
                viewModel.endStroke()
            }
    }
}
