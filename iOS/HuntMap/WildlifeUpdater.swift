import Foundation
import CryptoKit
import HuntCore

struct RemoteWildlifeRecord: Decodable, Identifiable {
    let pack_id: String
    let ground_id: String
    let sha256: String
    let size_bytes: Int
    let generated_at: String
    let source: String
    let license: String
    let source_url: String
    let taxa_count: Int
    var id: String { pack_id }
}

/// Explicit user-initiated updates. No background transfers or automatic publication.
@MainActor final class WildlifeUpdater: ObservableObject {
    @Published var candidates: [RemoteWildlifeRecord] = []
    @Published var status = "Обновления не проверялись"
    @Published var busy = false

    private func endpoint(server: String, path: String) throws -> URL {
        guard let base = URLComponents(string: server),
              base.scheme == "https" || (base.scheme == "http" && base.host == "127.0.0.1"),
              let host = base.host, !host.isEmpty, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else { throw UpdateError.invalidServer }
        guard let url = URL(string: path, relativeTo: base.url)?.absoluteURL else { throw UpdateError.invalidServer }
        return url
    }
    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw UpdateError.server }
        guard data.count <= WildlifeValidator.maxBytes else { throw UpdateError.oversized }
        return data
    }
    func check(server: String, groundID: String) async {
        busy = true; defer { busy = false }
        do {
            guard !groundID.isEmpty else { throw UpdateError.invalidGround }
            var components = URLComponents(url: try endpoint(server: server, path: "/v1/wildlife/manifest"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "ground_id", value: groundID)]
            let items = try JSONDecoder().decode([RemoteWildlifeRecord].self, from: try await fetch(components.url!))
            candidates = items.filter { $0.ground_id == groundID && $0.size_bytes > 0 && $0.size_bytes <= WildlifeValidator.maxBytes && $0.sha256.count == 64 }
            status = candidates.isEmpty ? "Для этой территории нет опубликованных каталогов" : "Доступных версий: \(candidates.count)"
        } catch { status = "Проверка обновлений: \(error.localizedDescription)" }
    }
    func install(_ record: RemoteWildlifeRecord, server: String, store: WildlifeStore) async {
        busy = true; defer { busy = false }
        do {
            guard record.pack_id.range(of: "^[A-Za-z0-9_-]{1,150}$", options: .regularExpression) != nil else { throw UpdateError.invalidPack }
            let data = try await fetch(endpoint(server: server, path: "/v1/wildlife/packs/\(record.pack_id)"))
            guard data.count == record.size_bytes,
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == record.sha256.lowercased() else { throw UpdateError.checksum }
            let pack = try WildlifeValidator.decode(data)
            guard pack.ground_id == record.ground_id,
                  pack.generated_at == record.generated_at,
                  pack.source == record.source, pack.license == record.license,
                  pack.source_url == record.source_url, pack.taxa.count == record.taxa_count else { throw UpdateError.mismatch }
            try store.installVerifiedBytes(data, packID: record.pack_id)
            status = "Пакет установлен и проверен: \(record.pack_id). Источник данных не подтверждён независимо"
        } catch { status = "Установка отклонена: \(error.localizedDescription)" }
    }
    enum UpdateError: LocalizedError {
        case invalidServer, invalidGround, invalidPack, server, oversized, checksum, mismatch
        var errorDescription: String? {
            switch self {
            case .invalidServer: "Требуется HTTPS-сервер (HTTP только для 127.0.0.1)"
            case .invalidGround: "Укажите идентификатор угодья"
            case .invalidPack: "Недопустимый идентификатор пакета"
            case .server: "Сервер вернул ошибку"
            case .oversized: "Пакет превышает ограничение"
            case .checksum: "Ошибка размера или SHA-256"
            case .mismatch: "Метаданные пакета не соответствуют манифесту"
            }
        }
    }
}
