import Foundation
import AppKit
import SwiftUI

struct AnimatedChar: Identifiable, Equatable {
    let id: Int
    let character: String
}

struct PinnedPill: Identifiable {
    let id = UUID()
    let chars: [AnimatedChar]
    let position: NSPoint
    let screenID: ObjectIdentifier
    let previousLine: String
    let previousLineChars: [AnimatedChar]
    let showPreviousLine: Bool
}

@MainActor
class SubtitleViewModel: ObservableObject {
    @Published var text: String = ""
    @Published var isActive: Bool = false
    @Published var cursorPosition: NSPoint = .zero
    @Published var activeScreenID: ObjectIdentifier?
    @Published var isVisible: Bool = false

    /// The previous line shown above, fading out when user starts typing on the new line
    @Published var previousLine: String = ""
    @Published var previousLineChars: [AnimatedChar] = []
    @Published var showPreviousLine: Bool = false
    /// Whether cursor is on a new blank line (Enter pressed, haven't typed yet)
    @Published var onNewLine: Bool = false

    @Published var drawingModeEnabled: Bool = false
    @Published var pillHiddenForDrawing: Bool = false
    var drawingToggleActive: Bool = false
    private var activatedFromDrawingToggle: Bool = false
    @Published var strokes: [[NSPoint]] = []
    /// Not @Published — updated at ~60Hz during drag; Canvas reads it via TimelineView to avoid PillView redraws
    var currentStroke: [NSPoint] = []
    @Published var isDrawing: Bool = false

    @Published var pinnedPills: [PinnedPill] = []

    @Published var dictationModeEnabled: Bool = false
    private var dictationBaseline: String = ""
    /// Number of characters already consumed from the current recognition session (for mid-session auto-advance)
    private var dictationSessionOffset: Int = 0
    /// Length of the last fullText received from speech recognition (used to sync baseline after keyboard edits)
    private var lastDictationFullTextLength: Int = 0

    @Published var animatedChars: [AnimatedChar] = []
    private var nextCharID = 0
    /// Cursor position for arrow key editing (0 = before first char, text.count = end)
    @Published var textCursorIndex: Int = 0

    var config: ConfigManager { ConfigManager.shared }

    var displayText: String {
        if isListening && text.isEmpty { return "Listening…" }
        if text.isEmpty && !onNewLine { return config.config.style.placeholderText }
        return text
    }

    var isPlaceholder: Bool { text.isEmpty && !onNewLine && isActive }

    var isListening: Bool { dictationModeEnabled && isActive }

    /// ID of the char at cursor position (for overlay cursor placement), nil when cursor is at end
    var editingCharID: Int? {
        guard textCursorIndex < animatedChars.count else { return nil }
        return animatedChars[textCursorIndex].id
    }

    private var idleTimer: Timer?

    func resetIdleTimer() {
        idleTimer?.invalidate()
        isVisible = true
        let timeout = config.config.behavior.idleTimeout
        guard timeout > 0 else { return }
        idleTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss()
            }
        }
    }

    func activate() {
        text = ""
        animatedChars = []
        nextCharID = 0
        textCursorIndex = 0
        previousLine = ""
        previousLineChars = []
        showPreviousLine = false
        onNewLine = false
        isActive = true
        isVisible = true
        resetIdleTimer()
    }

    func showPubbleForDrawing() {
        guard drawingToggleActive else { return }
        text = ""
        animatedChars = []
        nextCharID = 0
        textCursorIndex = 0
        previousLine = ""
        previousLineChars = []
        showPreviousLine = false
        onNewLine = false
        pillHiddenForDrawing = false
        resetIdleTimer()
    }

    func returnToDrawingMode() {
        guard drawingToggleActive else { return }
        pillHiddenForDrawing = true
        let fadeOut = config.config.behavior.fadeOutDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut) { [weak self] in
            guard let self, self.drawingToggleActive else { return }
            self.text = ""
            self.animatedChars = []
            self.nextCharID = 0
            self.textCursorIndex = 0
            self.previousLine = ""
            self.previousLineChars = []
            self.showPreviousLine = false
            self.onNewLine = false
        }
        resetIdleTimer()
    }

    func toggleDrawing() {
        drawingToggleActive.toggle()
        if drawingToggleActive {
            if !isActive {
                // Activate the overlay infrastructure without showing the pill
                text = ""
                animatedChars = []
                nextCharID = 0
                textCursorIndex = 0
                previousLine = ""
                previousLineChars = []
                showPreviousLine = false
                onNewLine = false
                isActive = true
                isVisible = true
                activatedFromDrawingToggle = true
            }
            drawingModeEnabled = true
            pillHiddenForDrawing = true
            resetIdleTimer()
        } else {
            let shouldDismiss = activatedFromDrawingToggle
            activatedFromDrawingToggle = false
            drawingModeEnabled = false
            if shouldDismiss {
                dismiss()
            } else {
                pillHiddenForDrawing = false
            }
        }
    }

    func toggleDictation() {
        if !dictationModeEnabled && SpeechManager.permissionsPreviouslyDenied() {
            showTemporaryPill(text: "Enable \(SpeechManager.deniedPermissionLabel()) Permission", timeout: 4)
            return
        }
        if dictationModeEnabled {
            dismiss()
        } else {
            dictationModeEnabled = true
            if !isActive { activate() }
            dictationBaseline = ""
            dictationSessionOffset = 0
            lastDictationFullTextLength = 0
        }
    }

    func pinCurrentPill() {
        guard isActive, !text.isEmpty else { return }
        guard let screenID = activeScreenID else { return }
        let pinned = PinnedPill(
            chars: animatedChars,
            position: cursorPosition,
            screenID: screenID,
            previousLine: previousLine,
            previousLineChars: previousLineChars,
            showPreviousLine: showPreviousLine
        )
        if pinnedPills.count >= 50 { pinnedPills.removeFirst() }
        pinnedPills.append(pinned)
        let sessionLength = lastDictationFullTextLength
        activate()
        // Reset dictation baseline so new pill starts fresh, but keep session offset
        // so already-recognised speech isn't replayed into the new pill
        dictationBaseline = ""
        dictationSessionOffset = sessionLength
    }

    func handleDictationResult(fullText: String, isFinal: Bool) {
        guard isActive else { return }
        if !isVisible { isVisible = true }

        lastDictationFullTextLength = fullText.count

        // Strip chars already consumed by a previous auto-advance within this session
        let sessionText: String
        if dictationSessionOffset > 0 && dictationSessionOffset <= fullText.count {
            sessionText = String(fullText[fullText.index(fullText.startIndex, offsetBy: dictationSessionOffset)...])
        } else {
            sessionText = fullText
        }
        let behavior = config.config.behavior
        let newText = dictationBaseline + sessionText
        let limit = behavior.charLimit

        // If we're on a new line and dictation adds text, fade out the previous line
        if onNewLine && showPreviousLine && !sessionText.isEmpty {
            withAnimation(.snappy(duration: 0.2)) {
                showPreviousLine = false
            }
            onNewLine = false
        }

        // Auto-advance when char limit hit (single-line mode only)
        // Loop so large speech chunks don't overflow the current line
        if !behavior.multiLine && newText.count >= limit {
            var remaining = newText
            while remaining.count >= limit {
                text = String(remaining.prefix(limit))
                rebuildAnimatedChars()
                let overflow = handleNewline()
                let beyondLimit = remaining.count > limit ? String(remaining.dropFirst(limit)) : ""
                remaining = overflow + beyondLimit
            }
            text = remaining
            textCursorIndex = remaining.count
            rebuildAnimatedChars()
            dictationBaseline = remaining
            dictationSessionOffset = fullText.count
            return
        }

        // Only rebuild animated chars when text actually changed (avoids redundant SwiftUI diffs from partial results)
        if text != newText {
            text = newText
            textCursorIndex = newText.count
            rebuildAnimatedChars()
            resetIdleTimer()
        }

        // On session final: commit full text as baseline for the next session
        if isFinal {
            dictationBaseline = text
            dictationSessionOffset = 0
        }
    }

    func dismissAll() {
        withAnimation(.easeOut(duration: 0.3)) {
            pinnedPills = []
        }
        dismiss()
    }

    func dismiss() {
        idleTimer?.invalidate()
        drawingToggleActive = false
        activatedFromDrawingToggle = false
        if pillHiddenForDrawing { pillHiddenForDrawing = false }
        // Stop dictation immediately so the audio engine doesn't run during fade
        dictationModeEnabled = false
        dictationBaseline = ""
        dictationSessionOffset = 0
        lastDictationFullTextLength = 0
        isActive = false
        isVisible = false
        // Delay content clearing so the fade animation renders with current appearance intact
        let fadeOut = config.config.behavior.fadeOutDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + fadeOut) { [weak self] in
            guard let self, !self.isActive else { return }
            self.text = ""
            self.animatedChars = []
            self.nextCharID = 0
            self.textCursorIndex = 0
            self.previousLine = ""
            self.previousLineChars = []
            self.showPreviousLine = false
            self.onNewLine = false
            self.clearStrokes()
        }
    }

    private func ensureActiveScreen() {
        if activeScreenID == nil,
           let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main {
            activeScreenID = ObjectIdentifier(screen)
        }
    }

    func showTemporaryPill(text: String, timeout: TimeInterval) {
        ensureActiveScreen()
        self.text = text
        onNewLine = false
        isActive = true
        isVisible = true
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.dismiss() }
        }
    }

    func showOnboarding() {
        showTemporaryPill(text: "Hey! Press ⌘+/ to show a Pubble!", timeout: 3)
    }

    func handleCharacter(_ char: String) {
        guard isActive else { return }
        if !isVisible { isVisible = true }

        // If we're on a new line and start typing, fade out the previous line
        if onNewLine && showPreviousLine {
            withAnimation(.snappy(duration: 0.2)) {
                showPreviousLine = false
            }
        }
        onNewLine = false

        let limit = config.config.behavior.charLimit
        let multiLine = config.config.behavior.multiLine

        // In single-line mode, auto-advance to a new line when the limit is hit
        if !multiLine && text.count >= limit {
            handleNewline()
        }

        if multiLine || text.count < limit {
            let atEnd = textCursorIndex >= text.count
            let insertIdx = text.index(text.startIndex, offsetBy: textCursorIndex)
            text.insert(contentsOf: char, at: insertIdx)
            textCursorIndex += char.count

            if atEnd {
                // Normal typing at end — use original animated append
                withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
                    for c in char {
                        animatedChars.append(AnimatedChar(id: nextCharID, character: String(c)))
                        nextCharID += 1
                    }
                }
            } else {
                // Mid-text insert — rebuild chars instantly
                rebuildAnimatedChars()
            }
        }
        syncDictationBaselineIfNeeded()
        resetIdleTimer()
    }

    /// Advance to a new line. In single-line mode, word-wraps: the last
    /// partial word carries over to the new line. Returns the overflow text
    /// (empty when there was no partial word or in multi-line mode).
    @discardableResult
    func handleNewline() -> String {
        guard isActive else { return "" }
        if !isVisible { isVisible = true }

        if config.config.behavior.multiLine {
            let insertIdx = text.index(text.startIndex, offsetBy: textCursorIndex)
            text.insert("\n", at: insertIdx)
            textCursorIndex += 1
            rebuildAnimatedChars()
            syncDictationBaselineIfNeeded()
            resetIdleTimer()
            return ""
        }

        // Word-wrap: split at last space so we don't cut mid-word
        var overflow = ""
        if let lastSpace = text.lastIndex(of: " ") {
            overflow = String(text[text.index(after: lastSpace)...])
            text = String(text[text.startIndex..<lastSpace])
            rebuildAnimatedChars()
        }

        // Move current text to previous line
        if !text.isEmpty {
            withAnimation(.snappy(duration: 0.2)) {
                previousLine = text
                previousLineChars = animatedChars
                showPreviousLine = true
                onNewLine = true
            }
        }

        // Start new line with overflow word
        if !overflow.isEmpty {
            text = overflow
            textCursorIndex = overflow.count
            rebuildAnimatedChars()
        } else {
            text = ""
            animatedChars = []
            textCursorIndex = 0
        }

        syncDictationBaselineIfNeeded()
        resetIdleTimer()
        return overflow
    }

    func handleBackspace() {
        guard isActive, !text.isEmpty, textCursorIndex > 0 else { return }
        let atEnd = textCursorIndex >= text.count

        let removeIdx = text.index(text.startIndex, offsetBy: textCursorIndex - 1)
        text.remove(at: removeIdx)
        textCursorIndex -= 1

        if atEnd {
            // Deleting from end — use original animated removeLast
            withAnimation(.easeIn(duration: 0.15)) {
                if !animatedChars.isEmpty {
                    animatedChars.removeLast()
                }
            }
        } else {
            // Mid-text delete — rebuild chars instantly
            rebuildAnimatedChars()
        }
        syncDictationBaselineIfNeeded()
        resetIdleTimer()
    }

    func handleArrowLeft() {
        guard isActive, textCursorIndex > 0 else { return }
        textCursorIndex -= 1
        resetIdleTimer()
    }

    func handleArrowRight() {
        guard isActive, textCursorIndex < text.count else { return }
        textCursorIndex += 1
        resetIdleTimer()
    }

    func handleMoveLineUp() {
        guard isActive else { return }
        guard config.config.behavior.multiLine else {
            textCursorIndex = 0; resetIdleTimer(); return
        }
        let currentIdx = text.index(text.startIndex, offsetBy: textCursorIndex)
        var lineStart = text.startIndex
        var s = currentIdx
        while s > text.startIndex {
            let prev = text.index(before: s)
            if text[prev] == "\n" { lineStart = s; break }
            s = prev
        }
        if lineStart == text.startIndex { textCursorIndex = 0; resetIdleTimer(); return }
        let column = text.distance(from: lineStart, to: currentIdx)
        let prevNewline = text.index(before: lineStart)
        var prevLineStart = text.startIndex
        var s2 = prevNewline
        while s2 > text.startIndex {
            let prev = text.index(before: s2)
            if text[prev] == "\n" { prevLineStart = s2; break }
            s2 = prev
        }
        let prevLineLength = text.distance(from: prevLineStart, to: prevNewline)
        textCursorIndex = text.distance(from: text.startIndex, to: text.index(prevLineStart, offsetBy: min(column, prevLineLength)))
        resetIdleTimer()
    }

    func handleMoveLineDown() {
        guard isActive else { return }
        guard config.config.behavior.multiLine else {
            textCursorIndex = text.count; resetIdleTimer(); return
        }
        let currentIdx = text.index(text.startIndex, offsetBy: textCursorIndex)
        var lineStart = text.startIndex
        var s = currentIdx
        while s > text.startIndex {
            let prev = text.index(before: s)
            if text[prev] == "\n" { lineStart = s; break }
            s = prev
        }
        let column = text.distance(from: lineStart, to: currentIdx)
        var lineEnd = currentIdx
        while lineEnd < text.endIndex && text[lineEnd] != "\n" { lineEnd = text.index(after: lineEnd) }
        if lineEnd >= text.endIndex { textCursorIndex = text.count; resetIdleTimer(); return }
        let nextLineStart = text.index(after: lineEnd)
        var nextLineEnd = nextLineStart
        while nextLineEnd < text.endIndex && text[nextLineEnd] != "\n" { nextLineEnd = text.index(after: nextLineEnd) }
        let nextLineLength = text.distance(from: nextLineStart, to: nextLineEnd)
        textCursorIndex = text.distance(from: text.startIndex, to: text.index(nextLineStart, offsetBy: min(column, nextLineLength)))
        resetIdleTimer()
    }

    func handleClearAll() {
        guard isActive else { return }
        text = ""
        animatedChars = []
        nextCharID = 0
        textCursorIndex = 0
        syncDictationBaselineIfNeeded()
        resetIdleTimer()
    }

    /// When the user edits text via keyboard during dictation, sync the baseline
    /// so the next speech result appends to the edited text instead of overwriting it.
    private func syncDictationBaselineIfNeeded() {
        guard dictationModeEnabled else { return }
        dictationBaseline = text
        dictationSessionOffset = lastDictationFullTextLength
    }

    /// Rebuilds animatedChars from text without animation (for mid-text edits)
    private func rebuildAnimatedChars() {
        animatedChars = text.map { c in
            let ac = AnimatedChar(id: nextCharID, character: String(c))
            nextCharID += 1
            return ac
        }
    }

    func startStroke(at point: NSPoint) {
        guard isActive, drawingModeEnabled else { return }
        currentStroke = [point]
        isDrawing = true
    }

    func continueStroke(to point: NSPoint) {
        guard isActive, drawingModeEnabled, !currentStroke.isEmpty else { return }
        currentStroke.append(point)
        resetIdleTimer()
    }

    func endStroke() {
        guard !currentStroke.isEmpty else { return }
        strokes.append(currentStroke)
        currentStroke = []
        isDrawing = false
        resetIdleTimer()
    }

    func clearStrokes() {
        strokes = []
        currentStroke = []
    }
}
