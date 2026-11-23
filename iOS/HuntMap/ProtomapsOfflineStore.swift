import Foundation
import CryptoKit

struct ProtomapsPack: Codable, Identifiable {
    let id: String
    let name: String
    let url: String
    let bounds: [Double]
    let bytes: Int64
    let sha256: String
    let minzoom: Int
    let maxzoom: Int
    var valid: Bool {
        id.range(of: "^[A-Za-z0-9_-]{1,90}$", options: .regularExpression) != nil &&
        bounds.count == 4 && bounds.allSatisfy(\.isFinite) &&
        bounds[0] < bounds[2] && bounds[1] < bounds[3] &&
        bytes > 127 && bytes <= 4_000_000_000 &&
        sha256.range(of: "^[0-9a-fA-F]{64}$", options: .regularExpression) != nil &&
        (0...15).contains(minzoom) && (minzoom...15).contains(maxzoom) &&
        URL(string: url)?.scheme == "https"
    }
}
private struct ProtomapsCatalog: Codable { let schema: String; let packs: [ProtomapsPack] }

@MainActor final class ProtomapsOfflineStore: ObservableObject {
    static let catalog = URL(string: "https://create.web-works.kz/maps/protomaps/catalog.json")!
    @Published private(set) var available: [ProtomapsPack] = []
    @Published private(set) var installed: [ProtomapsPack] = []
    @Published private(set) var onlineStyleURL: URL?
    @Published private(set) var offlineStyleURL: URL?
    @Published private(set) var busy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var assetsReady = false
    @Published private(set) var status = "Protomaps: обновите каталог"
    private var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Protomaps", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private var registry: URL { folder.appendingPathComponent("installed.json") }
    init() { restore() }
    func file(_ item: ProtomapsPack) -> URL { folder.appendingPathComponent(item.id + ".pmtiles") }
    private func restore() {
        assetsReady = ProtomapsAssets.ready(in: folder)
        guard let data = try? Data(contentsOf: registry),
              let saved = try? JSONDecoder().decode([ProtomapsPack].self, from: data) else { return }
        installed = saved.filter { $0.valid && FileManager.default.fileExists(atPath: file($0).path) }
        offlineStyleURL = ProtomapsVectorStyle.write(installed, folder: folder, local: true)
    }
    func refresh() async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.catalog)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2_000_000 else {
                throw NSError(domain: "Protomaps", code: 1, userInfo: [NSLocalizedDescriptionKey:"Каталог Protomaps не опубликован"])
            }
            let manifest = try JSONDecoder().decode(ProtomapsCatalog.self, from: data)
            guard manifest.schema == "hunt-protomaps-v1" else {
                throw NSError(domain: "Protomaps", code: 2, userInfo: [NSLocalizedDescriptionKey:"Неподдерживаемый каталог"])
            }
            available = manifest.packs.filter { $0.valid && URL(string:$0.url)?.host == Self.catalog.host }
            onlineStyleURL = ProtomapsVectorStyle.write(available, folder: folder, local: false)
            status = "Protomaps: \(available.count) регионов, скачано \(installed.count)"
        } catch { status = "Protomaps: \(error.localizedDescription). Локальные карты сохранены." }
    }
    func downloadAssets() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await installAssets()
    }

    private func installAssets() async {
        do {
            status = "Protomaps: скачивание подписей и значков"
            try await ProtomapsAssets.download(into: folder)
            assetsReady = ProtomapsAssets.ready(in: folder)
            offlineStyleURL = ProtomapsVectorStyle.write(installed, folder: folder, local: true)
            status = "Protomaps: подписи RU/KZ и значки сохранены для офлайна"
        } catch { status = "Геометрия карты доступна; подписи: \(error.localizedDescription)" }
    }

    func download(cells: [OfflineGridCell]) async {
        guard !busy, !cells.isEmpty else { return }
        let missing = available.filter { pack in
            cells.contains(where: { $0.intersects(pack.bounds) }) &&
            !installed.contains(where: { $0.id == pack.id && $0.sha256.lowercased() == pack.sha256.lowercased() })
        }
        guard !missing.isEmpty else {
            status = "Нет новых PMTiles для выбранной сетки"
            if !assetsReady { await downloadAssets() }
            return
        }
        busy = true; defer { busy = false }
        for (index, item) in missing.enumerated() {
            if Task.isCancelled { status = "Скачивание прервано, готовые PMTiles сохранены"; break }
            status = "PMTiles \(index+1)/\(missing.count): \(item.name)"
            progress = 0
            do {
                guard let url = URL(string: item.url), url.host == Self.catalog.host else {
                    throw NSError(domain: "Protomaps", code: 3, userInfo:[NSLocalizedDescriptionKey:"Небезопасный URL"])
                }
                let (temp, response) = try await URLSession.shared.download(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw NSError(domain:"Protomaps",code:4,userInfo:[NSLocalizedDescriptionKey:"Ошибка HTTP при скачивании"])
                }
                let attrs = try FileManager.default.attributesOfItem(atPath: temp.path)
                guard (attrs[.size] as? NSNumber)?.int64Value == item.bytes else {
                    throw NSError(domain:"Protomaps",code:5,userInfo:[NSLocalizedDescriptionKey:"Некорректный размер"])
                }
                let handle = try FileHandle(forReadingFrom: temp)
                defer { try? handle.close() }
                let magic = try handle.read(upToCount: 8) ?? Data()
                guard magic.count == 8, Data(magic.prefix(7)) == Data("PMTiles".utf8), magic[7] == 3 else {
                    throw NSError(domain:"Protomaps",code:6,userInfo:[NSLocalizedDescriptionKey:"Не PMTiles v3"])
                }
                try handle.seek(toOffset: 0)
                var checksum = SHA256()
                var consumed: Int64 = 0
                while true {
                    try Task.checkCancellation()
                    let bytes = try handle.read(upToCount: 1_048_576) ?? Data()
                    if bytes.isEmpty { break }
                    checksum.update(data: bytes)
                    consumed += Int64(bytes.count)
                    progress = Double(consumed) / Double(item.bytes)
                }
                let digest = checksum.finalize().map { String(format: "%02x", $0) }.joined()
                guard digest == item.sha256.lowercased() else {
                    throw NSError(domain:"Protomaps",code:7,userInfo:[NSLocalizedDescriptionKey:"SHA-256 не совпадает"])
                }
                let destination = file(item)
                // Replace only after successful integrity checks.
                let staged = folder.appendingPathComponent("install-\(UUID().uuidString).pmtiles")
                try FileManager.default.moveItem(at: temp, to: staged)
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
                } else { try FileManager.default.moveItem(at: staged, to: destination) }
                installed.removeAll { $0.id == item.id }
                installed.append(item)
                try JSONEncoder().encode(installed).write(to: registry, options: .atomic)
                offlineStyleURL = ProtomapsVectorStyle.write(installed, folder: folder, local: true)
                status = "Protomaps: установлено \(installed.count) регионов"
            } catch { status = "Ошибка \(item.name): \(error.localizedDescription)" }
        }
        if !installed.isEmpty && !assetsReady { await installAssets() }
    }
    func delete(_ item: ProtomapsPack) {
        guard !busy else { return }
        do {
            try FileManager.default.removeItem(at: file(item))
            installed.removeAll { $0.id == item.id }
            try JSONEncoder().encode(installed).write(to: registry, options: .atomic)
            offlineStyleURL = ProtomapsVectorStyle.write(installed, folder: folder, local: true)
            status = "Удалено: \(item.name)"
        } catch { status = error.localizedDescription }
    }
}
