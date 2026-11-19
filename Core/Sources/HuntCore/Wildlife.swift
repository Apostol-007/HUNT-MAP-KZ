import Foundation

/// Versioned offline wildlife pack. Nothing here conveys a legal hunting permission.
public struct WildlifePack: Codable, Sendable {
    public let schema_version: Int
    public let source: String
    public let source_url: String
    public let license: String
    public let generated_at: String
    public let ground_id: String
    public let taxa: [WildlifeTaxon]
}

public struct WildlifeTaxon: Codable, Identifiable, Sendable {
    public let id: String
    public let scientific_name: String
    public let name_ru: String?
    public let name_kk: String?
    public let category: String
    public let evidence_count: Int
    public let latest_evidence_at: String?
    public let source_record_url: String?
}

public enum WildlifeValidationError: Error, LocalizedError, Equatable {
    case oversized, invalidMetadata, invalidTaxon, duplicateTaxon, forbiddenLocation
    public var errorDescription: String? {
        switch self {
        case .oversized: "Пакет животных превышает допустимый размер"
        case .invalidMetadata: "Источник, лицензия, версия или дата некорректны"
        case .invalidTaxon: "Некорректные сведения о виде или доказательности"
        case .duplicateTaxon: "Повторяющийся идентификатор вида"
        case .forbiddenLocation: "Точные координаты и персональные данные запрещены в публичном каталоге"
        }
    }
}

public enum WildlifeValidator {
    public static let maxBytes = 8 * 1024 * 1024
    public static let maxTaxa = 10_000
    public static let categories: Set<String> = ["confirmed", "probable", "historical", "no_data"]

    /// Reject unknown fields, especially precise species coordinates, before decoding.
    public static func decode(_ data: Data) throws -> WildlifePack {
        guard data.count <= maxBytes else { throw WildlifeValidationError.oversized }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WildlifeValidationError.invalidMetadata
        }
        let rootKeys: Set<String> = ["schema_version", "source", "source_url", "license", "generated_at", "ground_id", "taxa"]
        guard Set(obj.keys).isSubset(of: rootKeys),
              let entries = obj["taxa"] as? [[String: Any]], entries.count <= maxTaxa else {
            throw WildlifeValidationError.forbiddenLocation
        }
        let taxonKeys: Set<String> = ["id", "scientific_name", "name_ru", "name_kk", "category", "evidence_count", "latest_evidence_at", "source_record_url"]
        for entry in entries {
            guard Set(entry.keys).isSubset(of: taxonKeys) else { throw WildlifeValidationError.forbiddenLocation }
        }
        let pack = try JSONDecoder().decode(WildlifePack.self, from: data)
        guard pack.schema_version == 1,
              validText(pack.source, max: 200), validText(pack.license, max: 200),
              validText(pack.ground_id, max: 150),
              validHTTPS(pack.source_url), validDate(pack.generated_at),
              pack.taxa.count <= maxTaxa else { throw WildlifeValidationError.invalidMetadata }
        var seen = Set<String>()
        for taxon in pack.taxa {
            guard validText(taxon.id, max: 150), validText(taxon.scientific_name, max: 200),
                  categories.contains(taxon.category), taxon.evidence_count >= 0,
                  (taxon.category != "confirmed" || taxon.evidence_count > 0),
                  (taxon.name_ru == nil || validText(taxon.name_ru!, max: 200)),
                  (taxon.name_kk == nil || validText(taxon.name_kk!, max: 200)),
                  (taxon.latest_evidence_at == nil || validDate(taxon.latest_evidence_at!)),
                  (taxon.source_record_url == nil || validHTTPS(taxon.source_record_url!)) else {
                throw WildlifeValidationError.invalidTaxon
            }
            guard seen.insert(taxon.id).inserted else { throw WildlifeValidationError.duplicateTaxon }
        }
        return pack
    }
    private static func validText(_ text: String, max: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= max
    }
    private static func validHTTPS(_ value: String) -> Bool {
        guard let url = URLComponents(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
    private static func validDate(_ value: String) -> Bool {
        // Accept ISO8601 UTC or offset timestamps with or without milliseconds.
        let milliseconds = ISO8601DateFormatter()
        milliseconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if milliseconds.date(from: value) != nil { return true }
        let f = ISO8601DateFormatter()
        return f.date(from: value) != nil
    }
}
