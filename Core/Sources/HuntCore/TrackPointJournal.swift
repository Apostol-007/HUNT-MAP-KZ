import Foundation

/// Each accepted record is committed atomically before it is published to the UI.
/// The caller owns session ordering; no concurrent writers.
public enum TrackPointJournal {
    private static func path(_ directory: URL, _ index: Int) -> URL {
        directory.appendingPathComponent(String(format: "%012lld.json", Int64(index)))
    }
    public static func append<T: Encodable>(_ point: T, index: Int, directory: URL) throws {
        guard index >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = path(directory, index)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(point)
        if fm.fileExists(atPath: destination.path) {
            guard try Data(contentsOf: destination) == bytes else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        #if os(iOS)
        try bytes.write(to: destination, options: [.atomic, .completeFileProtectionUnlessOpen])
        #else
        try bytes.write(to: destination, options: .atomic)
        #endif
    }
    public static func recover<T: Decodable>(_ type: T.Type, after count: Int, directory: URL) throws -> [T] {
        guard count >= 0 else { throw CocoaError(.fileReadCorruptFile) }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let indices = entries.filter { $0.pathExtension == "json" }.compactMap { Int($0.deletingPathExtension().lastPathComponent) }.filter { $0 >= count }.sorted()
        var points: [T] = []
        for index in indices {
            guard index == count + points.count else { throw CocoaError(.fileReadCorruptFile) }
            points.append(try JSONDecoder().decode(type, from: Data(contentsOf: path(directory,index))))
        }
        return points
    }
    public static func remove(directory: URL) throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }
}
