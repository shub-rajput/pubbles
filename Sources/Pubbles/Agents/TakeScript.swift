import Foundation

/// A showcase script an agent hands to Pubbles: scenes of steps, played on the stage.
/// Stored as `~/.config/pubbles/scripts/<id>/v<N>.json`, one file per version.
struct TakeScript: Codable, Sendable {
    var format: Int = 1
    var name: String
    var url: String
    var viewport: [Double]?
    var author: Author?
    var scenes: [Scene]

    struct Author: Codable, Sendable {
        var agent: String?
        var updated: String?
    }

    struct Scene: Codable, Sendable {
        var title: String
        var steps: [Step]
    }

    struct Step: Codable, Sendable {
        var action: String
        var target: String?   // CSS selector, or "text:Some words"
        var anchor: String?   // center | left | right | above | below
        var offset: [Double]? // [dx, dy] added to the anchor point
        var text: String?
        var key: String?
        var by: Double?       // scroll: pixels, positive = down
        var align: Double?    // scroll: where the target's top lands, as a fraction of viewport height
        var from: [Double]?   // arrow: start point relative to the arrow tip
        var pad: Double?
        var duration: Double?
        var seconds: Double?

        enum CodingKeys: String, CodingKey {
            case action = "do"
            case target, anchor, offset, text, key, by, align, from, pad, duration, seconds
        }
    }

    var viewportSize: CGSize {
        let v = viewport ?? [1440, 900]
        return CGSize(width: v.count > 0 ? v[0] : 1440, height: v.count > 1 ? v[1] : 900)
    }
}

enum ScriptStore {
    struct Entry: Sendable {
        let id: String
        let name: String
        let versions: [Int]
        var latest: Int { versions.last ?? 1 }
    }

    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pubbles/scripts")
    }

    static func fileURL(id: String, version: Int) -> URL {
        folder.appendingPathComponent(id).appendingPathComponent("v\(version).json")
    }

    /// Scripts with at least one readable version, by name.
    static func list() -> [Entry] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return dirs.compactMap { dir -> Entry? in
            let files = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            let versions = files.compactMap { name -> Int? in
                guard name.hasPrefix("v"), name.hasSuffix(".json") else { return nil }
                return Int(name.dropFirst().dropLast(5))
            }.sorted()
            guard let latest = versions.last,
                  let script = try? load(id: dir.lastPathComponent, version: latest) else { return nil }
            return Entry(id: dir.lastPathComponent, name: script.name, versions: versions)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func load(id: String, version: Int) throws -> TakeScript {
        let data = try Data(contentsOf: fileURL(id: id, version: version))
        return try JSONDecoder().decode(TakeScript.self, from: data)
    }
}
