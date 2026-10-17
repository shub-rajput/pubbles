import AppKit
import SwiftUI

// MARK: - Shared Permission Banner

struct PermissionBannerSection<Buttons: View>: View {
    let title: String
    let description: String
    let isGranted: Bool
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        if !isGranted {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(title)
                            Text(description)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    HStack(spacing: 8) { buttons() }
                }
            }
        }
    }
}

// MARK: - Permission Monitor

@MainActor
class PermissionMonitor: ObservableObject {
    static let accessibility = PermissionMonitor(check: AXIsProcessTrusted)
    static let microphone = PermissionMonitor(
        check: SpeechManager.currentPermissionsGranted,
        denied: SpeechManager.permissionsPreviouslyDenied
    )
    static let screenRecording = PermissionMonitor(check: CGPreflightScreenCaptureAccess)

    @Published private(set) var isGranted: Bool
    @Published private(set) var isDenied: Bool
    private let check: () -> Bool
    private let denied: () -> Bool
    private var timer: Timer?

    init(check: @escaping () -> Bool, denied: @escaping () -> Bool = { false }) {
        self.check = check
        self.denied = denied
        isGranted = check()
        isDenied = denied()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isGranted = self.check()
                self.isDenied = self.denied()
                if self.isGranted { self.timer?.invalidate(); self.timer = nil }
            }
        }
    }
}

// MARK: - Permission Banner Instances

struct AccessibilityBannerSection: View {
    @ObservedObject private var monitor = PermissionMonitor.accessibility

    var body: some View {
        PermissionBannerSection(
            title: "Please Enable Accessibility Permission",
            description: "Already showing as enabled? Quit the app, tap '−' on the Accessibility page to remove the permission, then re-open and re-grant.",
            isGranted: monitor.isGranted
        ) {
            Button("Open Settings") {
                NSWorkspace.shared.open(
                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                )
            }
            .buttonStyle(.borderedProminent)
            Button("Help") {
                NSWorkspace.shared.open(URL(string: "https://www.notion.so/Accessibility-Permission-error-3330f40884e9804aab43d81154577e79")!)
            }
        }
    }
}

struct MicrophoneBannerSection: View {
    @ObservedObject private var monitor = PermissionMonitor.microphone

    var body: some View {
        PermissionBannerSection(
            title: "Enable Microphone & Speech Recognition",
            description: "Required for Babble mode. Pubbles uses native on-device speech recognition.",
            isGranted: monitor.isGranted
        ) {
            if monitor.isDenied {
                Button("Open Settings") {
                    NSWorkspace.shared.open(
                        SpeechManager.deniedSettingsURL()
                    )
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Grant Access") {
                    Task { await SpeechManager.requestPermissions() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

/// Only needed to record scripted takes, so it's only asked for while agent access is on.
struct ScreenRecordingBannerSection: View {
    @ObservedObject private var monitor = PermissionMonitor.screenRecording
    @ObservedObject private var configManager = ConfigManager.shared

    var body: some View {
        if configManager.config.agents.enabled {
            PermissionBannerSection(
                title: "Enable Screen Recording",
                description: "Needed to record videos of scripts. Pubbles records only its stage window and its own bubbles.",
                isGranted: monitor.isGranted
            ) {
                Button("Grant Access") {
                    if !CGRequestScreenCaptureAccess() {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
                        )
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case style = "Style"
    case hotkeys = "Hotkeys"
    case settings = "Settings"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .style: "paintpalette.fill"
        case .hotkeys: "keyboard.fill"
        case .settings: "gearshape.fill"
        case .about: "info.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .style: .blue
        case .hotkeys: .indigo
        case .settings: .gray
        case .about: .gray
        }
    }
}

@MainActor
class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var selectedTab: SettingsTab = .style
}

struct SettingsView: View {
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 200)
        } detail: {
            detailView
        }
    }

    private var sidebar: some View {
        List(SettingsTab.allCases, selection: $nav.selectedTab) { tab in
            Label {
                Text(tab.rawValue)
            } icon: {
                Image(systemName: tab.icon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(tab.iconColor.gradient)
                    )
            }
            .tag(tab)
            .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let nsImage = NSImage(named: "pubbles-title") ?? Bundle.main.image(forResource: "pubbles-title") {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(height: 85)
                        .padding(.bottom, -16)
                } else {
                    Text("Pubbles").font(.headline)
                }
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
                    .font(.caption2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(Capsule())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch nav.selectedTab {
        case .style:
            StyleSettingsView()
        case .hotkeys:
            HotkeysSettingsView()
        case .settings:
            GeneralSettingsView()
        case .about:
            AboutSettingsView()
        }
    }
}

// MARK: - About

@MainActor
struct AboutSettingsView: View {
    @State private var updateStatus: String? = nil
    @State private var isChecking = false

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)

                VStack(spacing: 4) {
                    Text("Pubbles")
                        .font(.title2.bold())
                    Text("Version \(version)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Subtitles for your pointer.")
                    .font(.body)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button {
                        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/shubhangrajput")!)
                    } label: {
                        Label("Support Pubbles", systemImage: "heart.fill")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://github.com/shub-rajput/pubbles")!)
                    } label: {
                        Label("GitHub", systemImage: "arrow.up.right.square")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)

                    Button {
                        NSWorkspace.shared.open(URL(string: "https://www.notion.so/Pubbles-Help-Center-3330f40884e980f7a0f0d5689d37e94a")!)
                    } label: {
                        Label("Help", systemImage: "questionmark.circle")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                }

                Divider()
                    .frame(maxWidth: 260)

                VStack(spacing: 8) {
                    Button(action: checkForUpdates) {
                        if isChecking {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Checking...")
                            }
                        } else if UpdateChecker.shared.updateAvailable, let latest = UpdateChecker.shared.latestVersion {
                            Text("Update Available (\(latest))")
                        } else {
                            Text("Check for Updates")
                        }
                    }
                    .disabled(isChecking)

                    if let status = updateStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Text("Copyright \u{00A9} 2026 Shubhang Haresh Rajput")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }

    private func checkForUpdates() {
        if UpdateChecker.shared.updateAvailable {
            UpdateChecker.shared.promptAndUpdate()
        } else {
            isChecking = true
            updateStatus = nil
            UpdateChecker.shared.checkForUpdates(silent: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                isChecking = false
                if !UpdateChecker.shared.updateAvailable {
                    updateStatus = "Pubbles is up to date."
                }
            }
        }
    }
}

// MARK: - Pill Preview

struct PillPreview: View {
    let style: StyleConfig
    var text: String = "Hello world"

    @State private var appeared = false

    private var bgColor: Color { Color(hex: style.backgroundColor) ?? .blue }
    private var txtColor: Color { Color(hex: style.textColor) ?? .white }

    private var pillShape: UnevenRoundedRectangle {
        let r = style.cornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: style.pointerCorner ? 2 : r,
            bottomLeadingRadius: r,
            bottomTrailingRadius: r,
            topTrailingRadius: r,
            style: .continuous
        )
    }

    @ViewBuilder
    private var pillBackground: some View {
        if let gradientColors = style.backgroundGradient, gradientColors.count >= 2 {
            LinearGradient(
                colors: gradientColors.compactMap { Color(hex: $0) },
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .opacity(style.backgroundOpacity)
        } else {
            bgColor.opacity(style.backgroundOpacity)
        }
    }

    private var textFont: Font {
        if style.fontFamily == "system" {
            let weightMap: [String: Font.Weight] = [
                "ultraLight": .ultraLight, "thin": .thin, "light": .light,
                "regular": .regular, "medium": .medium, "semibold": .semibold,
                "bold": .bold, "heavy": .heavy, "black": .black,
            ]
            return .system(size: style.fontSize, weight: weightMap[style.fontWeight] ?? .medium)
        }
        return .custom(style.fontFamily, size: style.fontSize)
    }

    var body: some View {
        Text(text)
            .font(textFont)
            .foregroundStyle(txtColor)
            .padding(.horizontal, style.paddingH)
            .padding(.vertical, style.paddingV)
            .background { pillBackground }
            .clipShape(pillShape)
            .shadow(
                color: (Color(hex: style.shadowColor) ?? .black).opacity(style.shadowOpacity),
                radius: style.shadowRadius,
                x: style.shadowX,
                y: style.shadowY
            )
            .overlay(
                pillShape.strokeBorder(
                    (Color(hex: style.borderColor) ?? .white).opacity(style.borderOpacity),
                    lineWidth: style.borderWidth
                )
            )
            .scaleEffect(appeared ? 1.0 : 0.72)
            .opacity(appeared ? 1.0 : 0.0)
            .onAppear {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                    appeared = true
                }
            }
    }
}

// MARK: - Gradient Picker

struct GradientPicker: NSViewRepresentable {
    @Binding var colors: [String]

    func makeNSView(context: Context) -> GradientPickerView {
        let view = GradientPickerView()
        view.onColorsChanged = { colors = $0 }
        view.colors = colors
        return view
    }

    func updateNSView(_ nsView: GradientPickerView, context: Context) {
        if nsView.colors != colors {
            nsView.colors = colors
            nsView.needsDisplay = true
        }
    }
}

@MainActor
class GradientPickerView: NSView {
    var colors: [String] = []
    var onColorsChanged: (([String]) -> Void)?
    private var selectedIndex: Int?
    private var colorObserver: Any?
    private var clickMonitor: Any?
    private var keyMonitor: Any?

    private let barHeight: CGFloat = 14
    private let handleWidth: CGFloat = 12
    private let handleHeight: CGFloat = 20

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: handleHeight + 2)
    }

    private func location(for index: Int) -> CGFloat {
        guard colors.count >= 2 else { return 0.5 }
        return CGFloat(index) / CGFloat(colors.count - 1)
    }

    private func handleRect(for index: Int) -> NSRect {
        let trackWidth = bounds.width - handleWidth
        let x = location(for: index) * trackWidth
        let y = (bounds.height - handleHeight) / 2
        return NSRect(x: x, y: y, width: handleWidth, height: handleHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Draw gradient bar
        let barRect = NSRect(
            x: handleWidth / 2,
            y: (bounds.height - barHeight) / 2,
            width: bounds.width - handleWidth,
            height: barHeight
        )
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4)

        if colors.count >= 2 {
            let nsColors = colors.compactMap { NSColor.fromHex($0) }
            var locations = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
            if let gradient = NSGradient(colors: nsColors, atLocations: &locations, colorSpace: .sRGB) {
                ctx.saveGState()
                barPath.addClip()
                gradient.draw(in: barRect, angle: 0)
                ctx.restoreGState()
            }
        }

        // Bar border
        NSColor.white.withAlphaComponent(0.15).setStroke()
        barPath.lineWidth = 1
        barPath.stroke()

        // Draw handles
        for i in colors.indices {
            let rect = handleRect(for: i)
            let path = NSBezierPath(roundedRect: rect, xRadius: handleWidth / 2, yRadius: handleWidth / 2)

            // Fill with stop color
            (NSColor.fromHex(colors[i]) ?? .gray).setFill()
            path.fill()

            // Border
            let isSelected = selectedIndex == i
            if isSelected {
                NSColor.white.setStroke()
                path.lineWidth = 4
            } else {
                NSColor.white.withAlphaComponent(0.5).setStroke()
                path.lineWidth = 1
            }
            path.stroke()

            // Shadow
            let shadow = NSShadow()
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.shadowBlurRadius = 2
            shadow.shadowColor = .black.withAlphaComponent(0.3)
            shadow.set()
            path.fill()
            NSShadow().set() // reset
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Check if a handle was hit
        for i in colors.indices.reversed() {
            if handleRect(for: i).insetBy(dx: -3, dy: -3).contains(point) {
                selectedIndex = i
                needsDisplay = true
                openColorPanel(for: i)
                return
            }
        }

        // Tap on bar — add a stop
        let barRect = NSRect(
            x: handleWidth / 2,
            y: (bounds.height - barHeight) / 2,
            width: bounds.width - handleWidth,
            height: barHeight
        )
        if barRect.contains(point) && colors.count < 8 {
            colors.append(colors.last ?? "#000000")
            onColorsChanged?(colors)
            selectedIndex = colors.count - 1
            needsDisplay = true
            openColorPanel(for: colors.count - 1)
        }
    }

    private func removeMonitors() {
        if let obs = colorObserver {
            NotificationCenter.default.removeObserver(obs)
            colorObserver = nil
        }
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func openColorPanel(for index: Int) {
        removeMonitors()

        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        if let color = NSColor.fromHex(colors[index]) {
            panel.color = color
        }
        panel.orderFront(nil)

        colorObserver = NotificationCenter.default.addObserver(
            forName: NSColorPanel.colorDidChangeNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let idx = self.selectedIndex, self.colors.indices.contains(idx) else { return }
                let hex = panel.color.toHex()
                self.colors[idx] = hex
                self.onColorsChanged?(self.colors)
                self.needsDisplay = true
            }
        }

        // Deselect on clicks outside this view and the color panel
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            if event.window == panel { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if event.window == self.window && self.bounds.contains(point) { return event }
            self.deselect()
            return event
        }

        // Handle delete/escape even when color panel has focus
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.selectedIndex != nil else { return event }
            if event.keyCode == 51 || event.keyCode == 117 {
                if let index = self.selectedIndex, self.colors.count > 2, self.colors.indices.contains(index) {
                    self.colors.remove(at: index)
                    self.onColorsChanged?(self.colors)
                    self.deselect()
                    return nil
                }
            }
            if event.keyCode == 53 {
                self.deselect()
                return nil
            }
            return event
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { deselect() }
    }

    private func deselect() {
        removeMonitors()
        selectedIndex = nil
        needsDisplay = true
    }
}

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt64(h, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((val >> 16) & 0xFF) / 255,
            green: CGFloat((val >> 8) & 0xFF) / 255,
            blue: CGFloat(val & 0xFF) / 255,
            alpha: 1
        )
    }

    func toHex() -> String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        let r = Int(c.redComponent * 255)
        let g = Int(c.greenComponent * 255)
        let b = Int(c.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Color toHex (Color(hex:) init is in PillView.swift)

extension Color {
    func toHex() -> String {
        guard let components = NSColor(self).usingColorSpace(.sRGB)?.cgColor.components,
              components.count >= 3 else { return "#000000" }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
