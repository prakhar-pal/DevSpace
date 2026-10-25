import Foundation

// Port of src-tauri/src/layout.rs — persisted sidebar preferences (order,
// hidden set, friendly-name aliases, collapsed flag) stored as JSON at
// the platform configuration directory (same dir as the notify token). The
// JSON keys match the Rust/TS schema so an existing file migrates.
public struct Layout: Codable, Equatable, Sendable {
    public var order: [String]
    public var hidden: [String]
    public var aliases: [String: String]
    public var hiddenCollapsed: Bool

    public init(
        order: [String] = [],
        hidden: [String] = [],
        aliases: [String: String] = [:],
        hiddenCollapsed: Bool = false
    ) {
        self.order = order
        self.hidden = hidden
        self.aliases = aliases
        self.hiddenCollapsed = hiddenCollapsed
    }

    enum CodingKeys: String, CodingKey {
        case order, hidden, aliases
        case hiddenCollapsed = "hidden_collapsed"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        hidden = try c.decodeIfPresent([String].self, forKey: .hidden) ?? []
        aliases = try c.decodeIfPresent([String: String].self, forKey: .aliases) ?? [:]
        hiddenCollapsed = try c.decodeIfPresent(Bool.self, forKey: .hiddenCollapsed) ?? false
    }

    /// Tolerant parse: invalid/garbage JSON yields the default (empty) layout.
    public static func parse(_ json: String) -> Layout {
        (try? JSONDecoder().decode(Layout.self, from: Data(json.utf8))) ?? Layout()
    }

    public static func serialize(_ layout: Layout) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(layout) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

public enum LayoutStore {
    static func dir(paths: DevSpacePaths = .current) -> URL {
        paths.configDirectory
    }

    public static func load(paths: DevSpacePaths = .current) -> Layout {
        let file = dir(paths: paths).appendingPathComponent("layout.json")
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return Layout() }
        return Layout.parse(s)
    }

    /// Best-effort write — a lost preference is non-fatal.
    public static func save(_ layout: Layout, paths: DevSpacePaths = .current) {
        let d = dir(paths: paths)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? Layout.serialize(layout)
            .write(to: d.appendingPathComponent("layout.json"), atomically: true, encoding: .utf8)
    }
}
