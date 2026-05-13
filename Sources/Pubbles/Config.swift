import Foundation
import AppKit

struct CursorOffset: Codable, Sendable, Equatable {
    var x: CGFloat = 12
    var y: CGFloat = 12
}

struct StyleConfig: Codable, Sendable, Equatable {
    var backgroundColor: String = "#1F6BE8"
    var textColor: String = "#FFFFFF"
    var placeholderText: String = "Say something"
    var fontSize: CGFloat = 14
    var fontFamily: String = "system"
    var fontWeight: String = "regular"
    var cornerRadius: CGFloat = 16
    var pointerCorner: Bool = true
    var paddingH: CGFloat = 12
    var paddingV: CGFloat = 8
    var maxWidth: CGFloat = 300
    var cursorOffset: CursorOffset = CursorOffset()
    var borderColor: String = "#FFFFFF"
    var borderOpacity: Double = 0.2
    var borderWidth: CGFloat = 2
    var shadowColor: String = "#000000"
    var shadowOpacity: Double = 0.1
    var shadowRadius: CGFloat = 3
    var shadowX: CGFloat = 0
    var shadowY: CGFloat = 5
    var backgroundOpacity: Double = 1.0
    var vibrancy: String? = nil
    var backgroundGradient: [String]? = nil
    var glassEffect: Bool = false
    var drawingLineColor: String = "#FF0000"
    var drawingLineWidth: CGFloat = 3
    var pillScale: CGFloat = 1.0
    var pinnedBorderWidth: CGFloat = 3
    var pinnedBorderColor: String = "#FFFFFF"
    var pinIconSize: CGFloat = 14
    var pinIconColor: String = "#000000"
}

struct BehaviorConfig: Codable, Sendable {
    var idleTimeout: Double = 10
    var fadeOutDuration: Double = 0.5
    var fadeInDuration: Double = 0.2
    var charLimit: Int = 30
    var multiLine: Bool = false
    var clickToDismiss: Bool = false
    var wiggleEnabled: Bool = false
    var wiggleToActivate: String = "pubble"   // "pubble" | "babble" | "doodle"
    var wiggleSensitivity: String = "medium"  // "low" | "medium" | "high"
}

struct AppConfig: Codable, Sendable {
    var hotkey: String = "cmd+/"
    var drawingHotkey: String = "cmd"
    var drawingToggleHotkey: String = "cmd+d"
    var dictationHotkey: String = "cmd+m"
    var pinHotkey: String = "cmd"
    var theme: String? = nil
    var style: StyleConfig = StyleConfig()
    var behavior: BehaviorConfig = BehaviorConfig()
}

@MainActor
class ConfigManager: ObservableObject {
    static let shared = ConfigManager()

    @Published var config: AppConfig = AppConfig()
    @Published var isDirty: Bool = false

    private nonisolated let configURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pubbles")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }()

    private nonisolated let themesURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pubbles/themes")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var fileMonitor: DispatchSourceFileSystemObject?
    private var themeMonitor: DispatchSourceFileSystemObject?
    private var watchedTheme: String?

    init() {
        seedBuiltInThemes()
        loadConfig()
        watchConfig()
    }

    nonisolated func seedBuiltInThemes() {
        guard let bundlePath = Bundle.main.resourcePath else { return }
        let bundleThemes = URL(fileURLWithPath: bundlePath).appendingPathComponent("themes")
        guard FileManager.default.fileExists(atPath: bundleThemes.path) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bundleThemes, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "json" {
            let dest = themesURL.appendingPathComponent(file.lastPathComponent)
            // Skip files the user has saved to — don't overwrite their customizations
            if FileManager.default.fileExists(atPath: dest.path),
               let existingData = try? Data(contentsOf: dest),
               let existingDict = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any],
               existingDict["userModified"] as? Bool == true {
                continue
            }
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.copyItem(at: file, to: dest)
            }
        }
    }

    private nonisolated static func deepMerge(
        _ base: [String: Any],
        _ override: [String: Any]
    ) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let baseDict = result[key] as? [String: Any],
               let overrideDict = value as? [String: Any] {
                result[key] = deepMerge(baseDict, overrideDict)
            } else {
                result[key] = value
            }
        }
        return result
    }

    func loadConfig() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let defaultData = try? encoder.encode(AppConfig()),
              var merged = try? JSONSerialization.jsonObject(with: defaultData) as? [String: Any]
        else {
            config = AppConfig()
            return
        }

        var userDict: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: configURL.path),
           let userData = try? Data(contentsOf: configURL),
           let userObj = try? JSONSerialization.jsonObject(with: userData) as? [String: Any] {
            userDict = userObj
        } else {
            saveDefaultConfig()
            // Don't return early — continue loading so defaults are applied properly
        }

        // Treat nil and "default" identically — both load default.json
        let rawTheme = userDict["theme"] as? String
        let themeName = (rawTheme == nil || rawTheme == "default") ? "default" : rawTheme!
        let themeFile = themesURL.appendingPathComponent("\(themeName).json")
        if let themeData = try? Data(contentsOf: themeFile),
           let themeDict = try? JSONSerialization.jsonObject(with: themeData) as? [String: Any] {
            var themeConfig = themeDict
            themeConfig.removeValue(forKey: "name")
            themeConfig.removeValue(forKey: "userModified")
            merged = ConfigManager.deepMerge(merged, themeConfig)
        }

        // Capture baseline (defaults + theme) before user overrides for isDirty comparison
        let baselineMerged = merged

        merged = ConfigManager.deepMerge(merged, userDict)

        do {
            let mergedData = try JSONSerialization.data(withJSONObject: merged)
            config = try JSONDecoder().decode(AppConfig.self, from: mergedData)
            if let baselineData = try? JSONSerialization.data(withJSONObject: baselineMerged),
               let baselineConfig = try? JSONDecoder().decode(AppConfig.self, from: baselineData) {
                isDirty = config.style != baselineConfig.style
            } else {
                isDirty = false
            }
        } catch {
            print("Failed to load config: \(error). Using defaults.")
            config = AppConfig()
        }

        watchThemeFile()
    }

    private func saveDefaultConfig() {
        do {
            // Write minimal config so themes and color presets can take effect
            // (a full dump of defaults would override all theme values during merge)
            let minimal: [String: Any] = ["hotkey": "cmd+/"]
            let data = try JSONSerialization.data(withJSONObject: minimal, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: configURL)
        } catch {
            print("Failed to save default config: \(error)")
        }
    }

    private func watchConfig() {
        let fd = open(configURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        fileMonitor?.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.loadConfig()
            }
        }
        fileMonitor?.setCancelHandler {
            close(fd)
        }
        fileMonitor?.resume()
    }

    private func watchThemeFile() {
        let currentTheme = config.theme
        guard currentTheme != watchedTheme else { return }
        watchedTheme = currentTheme

        themeMonitor?.cancel()
        themeMonitor = nil

        guard let themeName = currentTheme else { return }
        let themeFile = themesURL.appendingPathComponent("\(themeName).json")
        let fd = open(themeFile.path, O_EVTONLY)
        guard fd >= 0 else { return }
        themeMonitor = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        themeMonitor?.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.loadConfig()
            }
        }
        themeMonitor?.setCancelHandler {
            close(fd)
        }
        themeMonitor?.resume()
    }

    func availableThemes() -> [(name: String, filename: String)] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: themesURL, includingPropertiesForKeys: nil
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { file -> (String, String)? in
                guard let data = try? Data(contentsOf: file),
                      let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let name = dict["name"] as? String
                else { return nil }
                let filename = file.deletingPathExtension().lastPathComponent
                return (name, filename)
            }
            .sorted { $0.name < $1.name }
    }

    func setTheme(_ themeName: String?) {
        guard var dict = readConfigDict() else { return }
        if let themeName {
            dict["theme"] = themeName
        } else {
            dict.removeValue(forKey: "theme")
        }
        writeConfigDict(dict)
    }

    func resetStyleOverrides() {
        guard var dict = readConfigDict() else { return }
        dict.removeValue(forKey: "style")
        writeConfigDict(dict)
    }

    func saveToActiveTheme() {
        let rawTheme = config.theme
        let themeName = (rawTheme == nil || rawTheme == "default") ? "default" : rawTheme!
        let themeFile = themesURL.appendingPathComponent("\(themeName).json")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let styleData = try? encoder.encode(config.style),
              let styleDict = try? JSONSerialization.jsonObject(with: styleData) as? [String: Any]
        else { return }

        // Preserve existing name field; fall back to filename
        var themeDict: [String: Any] = [:]
        if let existingData = try? Data(contentsOf: themeFile),
           let existingObj = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            themeDict = existingObj
        }
        let displayName = themeDict["name"] as? String ?? themeName.capitalized
        themeDict["name"] = displayName
        themeDict["style"] = styleDict
        themeDict["userModified"] = true

        do {
            let data = try JSONSerialization.data(
                withJSONObject: themeDict,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: themeFile)
        } catch {
            print("Failed to save theme: \(error)")
            return
        }

        // Clear overrides — file watcher reloads both files automatically
        resetStyleOverrides()
    }

    func createTheme(name: String) {
        // Build a filesystem-safe slug
        let slug = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let filename = slug.isEmpty ? "custom-theme" : slug
        let themeFile = themesURL.appendingPathComponent("\(filename).json")

        let themeDict: [String: Any] = [
            "name": name,
            "userModified": true
        ]

        do {
            let data = try JSONSerialization.data(
                withJSONObject: themeDict,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try data.write(to: themeFile)
        } catch {
            print("Failed to create theme: \(error)")
            return
        }

        setTheme(filename)
    }

    func openThemesFolder() {
        NSWorkspace.shared.open(themesURL)
    }

    func resetToFactory() {
        guard let bundlePath = Bundle.main.resourcePath else { return }
        let bundleThemes = URL(fileURLWithPath: bundlePath).appendingPathComponent("themes")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bundleThemes, includingPropertiesForKeys: nil
        ) else { return }

        for file in files where file.pathExtension == "json" {
            let dest = themesURL.appendingPathComponent(file.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: file, to: dest)
        }

        resetStyleOverrides()
    }

    /// Returns the filename of the next/previous theme in the sorted list, wrapping around.
    func peekTheme(forward: Bool) -> String {
        let themes = availableThemes()
        guard !themes.isEmpty else { return "default" }

        let currentTheme = config.theme ?? "default"
        let currentIndex = themes.firstIndex { $0.filename == currentTheme }

        if let currentIndex = currentIndex {
            if forward {
                return themes[(currentIndex + 1) % themes.count].filename
            } else {
                return themes[(currentIndex - 1 + themes.count) % themes.count].filename
            }
        } else {
            return forward ? themes[0].filename : themes[themes.count - 1].filename
        }
    }

    func cycleTheme(forward: Bool) {
        let themes = availableThemes()
        guard !themes.isEmpty else { return }

        // Cycle order: default (nil) → themes[0] → themes[1] → ... → default → ...
        let currentTheme = config.theme
        let currentIndex = themes.firstIndex { $0.filename == currentTheme }

        if let currentIndex = currentIndex {
            if forward {
                let next = currentIndex + 1
                if next >= themes.count {
                    setTheme(nil) // wrap to default
                } else {
                    setTheme(themes[next].filename)
                }
            } else {
                let prev = currentIndex - 1
                if prev < 0 {
                    setTheme(nil) // wrap to default
                } else {
                    setTheme(themes[prev].filename)
                }
            }
        } else {
            // Currently on default
            setTheme(forward ? themes[0].filename : themes[themes.count - 1].filename)
        }
    }

    private static let scalePresets: [CGFloat] = [0.8, 1.0, 1.3, 1.6, 2.0]

    func adjustPillScale(increase: Bool) {
        let current = config.style.pillScale
        let next: CGFloat
        if increase {
            next = Self.scalePresets.first(where: { $0 > current + 0.01 }) ?? current
        } else {
            next = Self.scalePresets.last(where: { $0 < current - 0.01 }) ?? current
        }
        guard next != current else { return }
        guard var dict = readConfigDict() else { return }
        var styleDict = dict["style"] as? [String: Any] ?? [:]
        styleDict["pillScale"] = next
        dict["style"] = styleDict
        writeConfigDict(dict)
    }

    func setHotkey(_ hotkey: String) {
        guard var dict = readConfigDict() else { return }
        dict["hotkey"] = hotkey
        writeConfigDict(dict)
    }

    func setDrawingHotkey(_ hotkey: String) {
        guard var dict = readConfigDict() else { return }
        dict["drawingHotkey"] = hotkey
        writeConfigDict(dict)
    }

    func setDrawingToggleHotkey(_ hotkey: String) {
        guard var dict = readConfigDict() else { return }
        dict["drawingToggleHotkey"] = hotkey
        writeConfigDict(dict)
    }

    func setDictationHotkey(_ hotkey: String) {
        guard var dict = readConfigDict() else { return }
        dict["dictationHotkey"] = hotkey
        writeConfigDict(dict)
    }

    func setPinHotkey(_ hotkey: String) {
        guard var dict = readConfigDict() else { return }
        dict["pinHotkey"] = hotkey
        writeConfigDict(dict)
    }

    private func readConfigDict() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return dict
    }

    private func writeConfigDict(_ dict: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: configURL)
        } catch {
            print("Failed to write config: \(error)")
        }
    }

    func removeStyleValue(_ key: String) {
        guard var dict = readConfigDict() else { return }
        if var styleDict = dict["style"] as? [String: Any] {
            styleDict.removeValue(forKey: key)
            dict["style"] = styleDict
            writeConfigDict(dict)
        }
    }

    func setStyleValue(_ key: String, _ value: Any) {
        guard var dict = readConfigDict() else { return }
        var styleDict = dict["style"] as? [String: Any] ?? [:]
        styleDict[key] = value
        dict["style"] = styleDict
        writeConfigDict(dict)
    }

    func setBehaviorValue(_ key: String, _ value: Any) {
        guard var dict = readConfigDict() else { return }
        var behaviorDict = dict["behavior"] as? [String: Any] ?? [:]
        behaviorDict[key] = value
        dict["behavior"] = behaviorDict
        writeConfigDict(dict)
    }
}
