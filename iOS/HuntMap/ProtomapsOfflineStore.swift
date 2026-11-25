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
        !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
private struct ProtomapsCatalog: Codable { let schema: String; let packs: [ProtomapsPack] }

@MainActor final class ProtomapsOfflineStore: ObservableObject {
    static let defaultCatalogURL = "https://create.web-works.kz/maps/"
    @Published private(set) var catalogAddress: String =
        UserDefaults.standard.string(forKey: "hunt.protomaps.catalogURL") ?? defaultCatalogURL
    @Published private(set) var loadedCatalogURL = ""
    @Published private(set) var diagnostic = "Каталог ещё не проверен"
    @Published private(set) var rejectedPacks = 0

    private var activeCatalog: URL? { Self.catalogCandidates(catalogAddress).first }

    /// Supports a concrete catalog URL or a hosting directory.
    /// A directory such as /maps/ is searched both at /maps/protomaps/catalog.json
    /// and /maps/catalog.json. The selected location is persisted.
    static func catalogCandidates(_ raw: String) -> [URL] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return [] }
        let path = components.path
        if path.lowercased().hasSuffix(".json") {
            return components.url.map { [$0] } ?? []
        }
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let suffixes = prefix.lowercased().hasSuffix("/protomaps/") ?
            ["catalog.json"] : ["protomaps/catalog.json", "catalog.json"]
        return suffixes.compactMap { suffix in
            components.path = prefix + suffix
            return components.url
        }
    }

    func setCatalogAddress(_ newValue: String) {
        catalogAddress = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(catalogAddress, forKey: "hunt.protomaps.catalogURL")
        loadedCatalogURL = ""
        diagnostic = "Адрес изменён. Нажмите «Проверить хостинг»."
        available = []
        onlineStyleURL = nil
    }

    private func downloadableURL(_ raw: String, catalog: URL) -> URL? {
        // Relative files are resolved from catalog.json, not the hosting root.
        guard let result = URL(string: raw, relativeTo: catalog)?.absoluteURL,
              let c = URLComponents(url: result, resolvingAgainstBaseURL: false),
              c.scheme == "https",
              c.host?.lowercased() == catalog.host?.lowercased(),
              c.user == nil, c.password == nil, c.fragment == nil,
              c.path.lowercased().hasSuffix(".pmtiles"),
              !c.path.split(separator: "/").contains("..") else { return nil }
        return result
    }
    @Published private(set) var available: [ProtomapsPack] = []
    @Published private(set) var installed: [ProtomapsPack] = []
    @Published private(set) var onlineStyleURL: URL?
    @Published private(set) var offlineStyleURL: URL?
    @Published private(set) var hybridOfflineStyleURL: URL?
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
        hybridOfflineStyleURL = ProtomapsVectorStyle.write(installed, folder: folder, local: true, hybrid: true)
    }
    func refresh() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        available = []
        onlineStyleURL = nil
        loadedCatalogURL = ""
        rejectedPacks = 0
        let candidates = Self.catalogCandidates(catalogAddress)
        guard !candidates.isEmpty else {
            diagnostic = "Неверный HTTPS-адрес. Укажите полный catalog.json или каталог /maps/."
            status = diagnostic
            return
        }
        var failures: [String] = []
        for catalog in candidates {
            do {
                var request = URLRequest(url: catalog)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.timeoutInterval = 20
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard statusCode == 200 else {
                    failures.append("\(catalog.absoluteString): HTTP \(statusCode)")
                    continue
                }
                guard data.count <= 2_000_000 else {
                    failures.append("\(catalog.absoluteString): файл каталога слишком большой")
                    continue
                }
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    failures.append("\(catalog.absoluteString): вместо JSON получен другой документ")
                    continue
                }
                let schema = root["schema"] as? String ?? "не указана"
                guard schema == "hunt-protomaps-v1" else {
                    failures.append("\(catalog.absoluteString): схема «\(schema)» вместо hunt-protomaps-v1")
                    continue
                }
                let manifest = try JSONDecoder().decode(ProtomapsCatalog.self, from: data)
                let validated = manifest.packs.compactMap { item -> ProtomapsPack? in
                    guard item.valid, let url = downloadableURL(item.url, catalog: catalog)
                    else { return nil }
                    return ProtomapsPack(id: item.id, name: item.name, url: url.absoluteString,
                                         bounds: item.bounds, bytes: item.bytes,
                                         sha256: item.sha256, minzoom: item.minzoom,
                                         maxzoom: item.maxzoom)
                }
                rejectedPacks = manifest.packs.count - validated.count
                available = validated
                loadedCatalogURL = catalog.absoluteString
                onlineStyleURL = ProtomapsVectorStyle.write(validated, folder: folder, local: false)
                diagnostic = "HTTP 200 · \(catalog.absoluteString) · в каталоге \(manifest.packs.count), принято \(validated.count), отклонено \(rejectedPacks)"
                status = validated.isEmpty
                    ? "Каталог прочитан, но доступных PMTiles нет. Проверьте packs и поля файлов."
                    : "Protomaps: найдено \(validated.count), установлено \(installed.count)"
                return
            } catch {
                failures.append("\(catalog.absoluteString): \(error.localizedDescription)")
            }
        }
        diagnostic = failures.joined(separator: "\n")
        status = "Не удалось прочитать каталог Protomaps. Сохранённые карты на iPhone не удалены."
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
        hybridOfflineStyleURL = ProtomapsVectorStyle.write(installed, folder: folder, local: true, hybrid: true)
            status = "Protomaps: подписи RU/KZ и значки сохранены для офлайна"
        } catch {
            AppDiagnosticLog.shared.recordError(subsystem: "Карты", operation: "Подписи Protomaps", error: error, usedCache: assetsReady)
            status = "Геометрия карты доступна; подписи: \(error.localizedDescription)"
        }
    }

    /// Automatically download all newly published packs. The existing installer
    /// performs size, PMTiles v3 magic and SHA-256 verification before replacement.
    func downloadAllAvailable() async {
        await installMissing(available)
    }
    func downloadPack(id: String) async {
        guard !busy, let item = available.first(where: { $0.id == id }) else { return }
        await installMissing([item])
    }
    private func installMissing(_ requested: [ProtomapsPack]) async {
        guard !busy else { return }
        let missing = requested.filter { item in
            !installed.contains(where: { $0.id == item.id && $0.sha256.lowercased() == item.sha256.lowercased() })
        }
        guard !missing.isEmpty else {
            status = "Все доступные PMTiles установлены"
            if !assetsReady { await downloadAssets() }
            return
        }
        busy = true; defer { busy = false }
        for (index, item) in missing.enumerated() {
            if Task.isCancelled { status = "Скачивание прервано, готовые PMTiles сохранены"; break }
            status = "PMTiles \(index+1)/\(missing.count): \(item.name)"
            progress = 0
            do {
                guard let catalog = URL(string: loadedCatalogURL),
                      let url = downloadableURL(item.url, catalog: catalog) else {
                    throw NSError(domain: "Protomaps", code: 3, userInfo:[NSLocalizedDescriptionKey:"Небезопасный URL"])
                }
                if let capacity = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   capacity < item.bytes * 2 + 50_000_000 {
                    throw NSError(domain: "Protomaps", code: 8, userInfo: [NSLocalizedDescriptionKey: "Недостаточно свободного места"])
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
        hybridOfflineStyleURL = ProtomapsVectorStyle.write(installed, folder: folder, local: true, hybrid: true)
                status = "Protomaps: установлено \(installed.count) регионов"
            } catch {
                AppDiagnosticLog.shared.recordError(subsystem: "Карты", operation: "Загрузка PMTiles \(item.id)", error: error, usedCache: !installed.isEmpty)
                status = "Ошибка \(item.name): \(error.localizedDescription)"
            }
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
        hybridOfflineStyleURL = ProtomapsVectorStyle.write(installed, folder: folder, local: true, hybrid: true)
            status = "Удалено: \(item.name)"
        } catch { status = error.localizedDescription }
    }
}