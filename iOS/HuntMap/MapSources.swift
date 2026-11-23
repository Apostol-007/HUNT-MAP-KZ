import Foundation

/// MapLibre-compatible cartographic sources. MapTiler requires a user-provided key.
/// The public OpenFreeMap source is used as a no-key fallback, not for bulk download.
enum MapBasemap: String, CaseIterable, Identifiable {
    case bright = "bright"
    case outdoors = "outdoors"
    case light = "light"
    case satellite = "satellite"

    var id: String { rawValue }
    var name: String {
        switch self {
        case .bright: return "Подробная"
        case .outdoors: return "Туристическая"
        case .light: return "Светлая"
        case .satellite: return "Спутник"
        }
    }
    var symbol: String {
        switch self {
        case .bright: return "map.fill"
        case .outdoors: return "mountain.2.fill"
        case .light: return "sun.max.fill"
        case .satellite: return "globe.europe.africa.fill"
        }
    }

    func styleURL(apiKey: String) -> URL? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            let mapID: String
            switch self {
            case .bright: mapID = "streets-v4"
            case .outdoors: mapID = "outdoor-v4"
            case .light: mapID = "streets-v4-light"
            case .satellite: mapID = "satellite"
            }
            var components = URLComponents(string: "https://api.maptiler.com/maps/\(mapID)/style.json")
            components?.queryItems = [URLQueryItem(name: "key", value: key)]
            return components?.url
        }
        // Without a key the satellite mode cannot legally use MapTiler.
        let style: String
        switch self {
        case .bright: style = "bright"
        case .outdoors: style = "liberty"
        case .light: style = "positron"
        case .satellite: return nil
        }
        return URL(string: "https://tiles.openfreemap.org/styles/\(style)")
    }
}
