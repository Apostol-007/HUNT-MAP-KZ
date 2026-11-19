import Foundation
import HuntCore

@MainActor final class BoundaryDownloader: ObservableObject {
    @Published private(set) var message = "Публичные границы не загружены"
    @Published private(set) var busy = false

    func fetch(server: String, groundID: String, model: FieldModel) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard let base = URL(string: server), base.scheme == "https", base.host != nil,
                  groundID.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression) != nil else {
                throw URLError(.badURL)
            }
            let endpoint = base.appendingPathComponent("v1/grounds/\(groundID)/geojson")
            var request = URLRequest(url: endpoint)
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 20_000_000 else { throw URLError(.badServerResponse) }
            let path = FileManager.default.temporaryDirectory.appendingPathComponent("boundary-\(UUID().uuidString).geojson")
            defer { try? FileManager.default.removeItem(at: path) }
            try data.write(to: path, options: .atomic)
            let zones = try GeoJSONImport.load(path)
            guard !zones.isEmpty else { throw URLError(.cannotParseResponse) }
            model.setImportedZones(zones)
            message = "Загружено геозон: \(zones.count). Юридическая актуальность требует проверки первоисточника"
        } catch { message = "Ошибка загрузки границ: \(error.localizedDescription)" }
    }
}
