import Foundation

public enum TrackExportCleanup {
    public static func removeExpired(in directory: URL, now: Date = Date(), retention: TimeInterval = 7 * 24 * 3600) throws -> Int {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles])
        var removed = 0
        for url in entries {
            try Task.checkCancellation()
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "gpx", name.hasPrefix("route-"),
                  UUID(uuidString: String(name.dropFirst(6))) != nil else { continue }
            let metadata = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
            guard metadata.isRegularFile == true, metadata.isSymbolicLink != true,
                  let modified = metadata.contentModificationDate, now.timeIntervalSince(modified) >= retention else { continue }
            try fm.removeItem(at: url)
            removed += 1
        }
        return removed
    }
}
