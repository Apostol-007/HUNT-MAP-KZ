import Foundation

/// Copies official Protomaps glyph ranges and sprite resources into the app's
/// Application Support directory. They are small map-renderer assets, not UI fonts.
enum ProtomapsAssets {
    private static let root = "https://protomaps.github.io/basemaps-assets"
    private static let ranges = ["0-255", "256-511", "1024-1279", "1280-1535"]
    private static let sprites = ["light.json", "light.png", "light@2x.json", "light@2x.png"]

    static func ready(in folder: URL) -> Bool {
        let fonts = folder.appendingPathComponent("fonts/Noto Sans Regular", isDirectory: true)
        let icons = folder.appendingPathComponent("sprites/v4", isDirectory: true)
        return ranges.allSatisfy { FileManager.default.fileExists(atPath: fonts.appendingPathComponent($0 + ".pbf").path) } &&
               sprites.allSatisfy { FileManager.default.fileExists(atPath: icons.appendingPathComponent($0).path) }
    }

    static func download(into folder: URL) async throws {
        let fonts = folder.appendingPathComponent("fonts/Noto Sans Regular", isDirectory: true)
        let spritesDir = folder.appendingPathComponent("sprites/v4", isDirectory: true)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spritesDir, withIntermediateDirectories: true)
        let items: [(String, URL)] =
            ranges.map { range in
                ("\(root)/fonts/Noto%20Sans%20Regular/\(range).pbf",
                 fonts.appendingPathComponent(range + ".pbf"))
            } +
            sprites.map { name in
                ("\(root)/sprites/v4/\(name)",
                 spritesDir.appendingPathComponent(name))
            }
        for (address, target) in items {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: target.path),
               let size = try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 100 {
                continue
            }
            guard let url = URL(string: address) else { throw URLError(.badURL) }
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count > 100, data.count < 8_000_000 else {
                throw NSError(domain: "ProtomapsAssets", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Недоступен картографический ресурс: \(address)"])
            }
            try data.write(to: target, options: [.atomic])
        }
    }

    static func glyphs(in folder: URL) -> String {
        folder.appendingPathComponent("fonts", isDirectory: true).absoluteString +
            "{fontstack}/{range}.pbf"
    }

    static func sprite(in folder: URL) -> String {
        folder.appendingPathComponent("sprites/v4/light").absoluteString
    }
}
