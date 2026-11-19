import Foundation
import HuntCore

/// Privacy-first local catalog: no background network requests, no server account.
@MainActor final class WildlifeStore: ObservableObject {
    @Published private(set) var packs: [WildlifePack] = []
    @Published var message = "Каталог животных не загружен"

    private var directory: URL {
        let path = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WildlifePacks", isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    init() { reload() }
    func reload() {
        var valid: [WildlifePack] = []
        for file in ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
            if let bytes = try? Data(contentsOf: file), let item = try? WildlifeValidator.decode(bytes) { valid.append(item) }
        }
        packs = valid
        message = valid.isEmpty ? "Каталог животных не загружен" : "Офлайн-каталогов: \(valid.count)"
    }
    func importFile(_ incoming: URL) {
        let hasAccess = incoming.startAccessingSecurityScopedResource()
        defer { if hasAccess { incoming.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: incoming.path)
            guard let fileSize = (attributes[.size] as? NSNumber)?.intValue,
                  fileSize <= WildlifeValidator.maxBytes else { throw WildlifeValidationError.oversized }
            let bytes = try Data(contentsOf: incoming)
            let pack = try WildlifeValidator.decode(bytes)
            // Stable filename scoped to source + ground. Prevent traversal with UUID filename.
            let target = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
            try bytes.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
            reload()
            message = "Импортирован каталог \(pack.ground_id): \(pack.taxa.count) видов. Источник не проверен автоматически"
        } catch {
            message = "Импорт отклонён: \(error.localizedDescription)"
        }
    }
    func installVerifiedBytes(_ data: Data, packID: String) throws {
        _ = try WildlifeValidator.decode(data)
        guard packID.range(of: "^[A-Za-z0-9_-]{1,150}$", options: .regularExpression) != nil else {
            throw WildlifeValidationError.invalidMetadata
        }
        let target = directory.appendingPathComponent("remote-\(packID).json")
        // Atomic replace; the previous verified copy survives validation failures.
        try data.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
        reload()
    }
    func remove(at index: Int) {
        guard packs.indices.contains(index) else { return }
        let matches = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path })
            .filter { file in
                guard let data = try? Data(contentsOf: file), let item = try? WildlifeValidator.decode(data) else { return false }
                return item.ground_id == packs[index].ground_id && item.source == packs[index].source && item.generated_at == packs[index].generated_at
            }
        for file in matches { try? FileManager.default.removeItem(at: file) }
        reload()
    }
}
