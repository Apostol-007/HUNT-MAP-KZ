import Foundation

/// MapLibre Native is the only rendering engine. Providers supply style JSON and tiles.
/// Public OpenFreeMap styles are online-only and must not be bulk-downloaded.
/// MapTiler styles require a configured, restricted client-side API key.
enum MapBasemap: String, CaseIterable, Identifiable {
    case bright = "bright"
    case outdoors = "outdoors"
    case light = "light"
    case dark = "dark"
    case fiord = "fiord"
    case threeD = "3d"
    case topo = "topo"
    case satellite = "satellite"
    case hybrid = "hybrid"

    var id: String { rawValue }

    var name: String {
        switch self {
        case .bright: return "Подробная"
        case .outdoors: return "Туристическая"
        case .light: return "Светлая"
        case .dark: return "Тёмная"
        case .fiord: return "Рельефная"
        case .threeD: return "3D-город"
        case .topo: return "Топографическая"
        case .satellite: return "Спутник"
        case .hybrid: return "Гибрид"
        }
    }

    var detail: String {
        switch self {
        case .bright: return "Дороги и населённые пункты"
        case .outdoors: return "Тропы и ориентиры OSM"
        case .light: return "Минимальная подложка"
        case .dark: return "Контрастная ночная карта"
        case .fiord: return "Акцент на природный рельеф"
        case .threeD: return "Объёмная городская схема"
        case .topo: return "Топография MapTiler"
        case .satellite: return "Спутниковые снимки MapTiler"
        case .hybrid: return "Спутник с подписями MapTiler"
        }
    }

    var symbol: String {
        switch self {
        case .bright: return "map.fill"
        case .outdoors: return "figure.hiking"
        case .light: return "sun.max.fill"
        case .dark: return "moon.stars.fill"
        case .fiord: return "mountain.2.fill"
        case .threeD: return "building.2.crop.circle"
        case .topo: return "map.circle"
        case .satellite: return "globe.europe.africa.fill"
        case .hybrid: return "square.3.layers.3d"
        }
    }

    var requiresMapTilerKey: Bool {
        switch self {
        case .topo, .satellite, .hybrid: return true
        default: return false
        }
    }

    func isAvailable(apiKey: String) -> Bool {
        !requiresMapTilerKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func styleURL(apiKey: String) -> URL? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresMapTilerKey {
            guard !key.isEmpty else { return nil }
            let mapID: String
            switch self {
            case .topo: mapID = "topo-v4"
            case .satellite: mapID = "satellite-v4"
            case .hybrid: mapID = "hybrid-v4"
            default: return nil
            }
            var components = URLComponents(string: "https://api.maptiler.com/maps/\(mapID)/style.json")
            components?.queryItems = [URLQueryItem(name: "key", value: key)]
            return components?.url
        }
        let style: String
        switch self {
        case .bright: style = "bright"
        case .outdoors: style = "liberty"
        case .light: style = "positron"
        case .dark: style = "dark"
        case .fiord: style = "fiord"
        case .threeD: style = "3d"
        default: return nil
        }
        return URL(string: "https://tiles.openfreemap.org/styles/\(style)")
    }
}
