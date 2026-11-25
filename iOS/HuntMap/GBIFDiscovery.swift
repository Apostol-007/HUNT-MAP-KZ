import Foundation

struct GBIFTaxon: Identifiable, Codable { let id: String; let name: String }

enum GBIFDiscovery {
    private static var cacheURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("gbif_taxa.json")
    }
    static func cached() -> [GBIFTaxon] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return (try? JSONDecoder().decode([GBIFTaxon].self, from: data)) ?? []
    }
    struct FacetResult: Decodable {
        struct Facet: Decodable {
            struct Count: Decodable { let name: String; let count: Int }
            let field: String
            let counts: [Count]
        }
        let facets: [Facet]?
    }
    /// Aggregated country-level public GBIF names only: no observation coordinates are retained.
    /// GBIF occurrence facets are observational evidence, not a verified list for hunting grounds.
    static func fetchKazakhstan() async throws -> [GBIFTaxon] {
        var components = URLComponents(string: "https://api.gbif.org/v1/occurrence/search")!
        components.queryItems = [
            URLQueryItem(name: "country", value: "KZ"),
            URLQueryItem(name: "hasCoordinate", value: "true"),
            URLQueryItem(name: "limit", value: "0"),
            URLQueryItem(name: "facet", value: "scientificName"),
            URLQueryItem(name: "facetLimit", value: "100")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue("HUNT-MAP-KZ/0.9 (+https://github.com/; biodiversity viewer)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else {
            throw URLError(.badServerResponse)
        }
        let parsed = try JSONDecoder().decode(FacetResult.self, from: data)
        let counts = parsed.facets?.first(where: { $0.field.lowercased() == "scientificname" })?.counts ?? []
        let taxa = counts.filter { !$0.name.isEmpty }.map { GBIFTaxon(id: $0.name, name: "\($0.name) · записей: \($0.count)") }
        try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(taxa).write(to: cacheURL, options: .atomic)
        return taxa
    }
}
