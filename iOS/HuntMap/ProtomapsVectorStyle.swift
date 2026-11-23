import Foundation

/// Source layers follow Protomaps Basemap v4 (roads, water, landcover, landuse, buildings).
/// This independent visual style has no network glyph dependencies. Offline name labels
/// require separately packaged fontstack glyphs, not implemented in this minimal style.
enum ProtomapsVectorStyle {
    static func write(_ regions: [ProtomapsPack], folder: URL, local: Bool) -> URL? {
        guard !regions.isEmpty else { return nil }
        var sources: [String: Any] = [:]
        var layers: [[String: Any]] = [
            ["id":"background","type":"background","paint":["background-color":"#e9eee2"]]
        ]
        func fill(_ id: String, _ source: String, _ name: String, _ color: String, _ filter: [Any]? = nil) {
            var layer: [String: Any] = ["id":id,"type":"fill","source":source,"source-layer":name,
                                        "paint":["fill-color":color,"fill-opacity":0.85]]
            if let filter { layer["filter"] = filter }
            layers.append(layer)
        }
        func line(_ id: String, _ source: String, _ name: String, _ color: String, _ width: Any,
                  _ filter: [Any]? = nil, dash: [Double]? = nil) {
            var paint: [String: Any] = ["line-color":color,"line-width":width]
            if let dash { paint["line-dasharray"] = dash }
            var layer: [String: Any] = ["id":id,"type":"line","source":source,
                                        "source-layer":name,"paint":paint]
            if let filter { layer["filter"] = filter }
            layers.append(layer)
        }
        for (index, item) in regions.enumerated() {
            let id = "protomaps_\(index)"
            let archive = folder.appendingPathComponent(item.id + ".pmtiles")
            if local && !FileManager.default.fileExists(atPath: archive.path) { continue }
            let address = local ? archive.absoluteString : item.url
            sources[id] = ["type":"vector","url":"pmtiles://\(address)",
                           "attribution":"© OpenStreetMap contributors · Protomaps"]
            fill("grass_\(index)",id,"landcover","#a6c99a",
                 ["in","kind","forest","grassland","scrub"])
            fill("parks_\(index)",id,"landuse","#8fbc86",
                 ["in","kind","forest","wood","park","grass","meadow"])
            fill("water_\(index)",id,"water","#7eafd1")
            fill("buildings_\(index)",id,"buildings","#c7c5b9")
            line("highways_\(index)",id,"roads","#e1ab68",
                 ["interpolate",["linear"],["zoom"],5,0.6,15,4.0],
                 ["in","kind","highway","major_road","minor_road"])
            line("minor_\(index)",id,"roads","#f8f8f3",
                 ["interpolate",["linear"],["zoom"],10,0.5,15,2.6],
                 ["==","kind","minor_road"])
            line("trails_\(index)",id,"roads","#986b41",
                 ["interpolate",["linear"],["zoom"],9,0.7,15,2.3],
                 ["in","kind_detail","path","track","footway","steps","bridleway","cycleway","pedestrian"],
                 dash:[2,2])
        }
        guard !sources.isEmpty else { return nil }
        let canLabel = !local || ProtomapsAssets.ready(in: folder)
        if canLabel {
            for (i, _) in regions.enumerated() {
                let id = "protomaps_\(i)"
                let label: [String: Any] = [
                    "id": "place_names_\(i)", "type": "symbol",
                    "source": id, "source-layer": "places",
                    "layout": [
                        "text-field": ["coalesce", ["get", "name:ru"], ["get", "name:kk"], ["get", "name"]],
                        "text-font": ["Noto Sans Regular"],
                        "text-size": ["interpolate", ["linear"], ["zoom"], 5, 10, 14, 15],
                        "text-max-width": 10
                    ],
                    "paint": ["text-color": "#263e36", "text-halo-color": "#f5f6f0", "text-halo-width": 1.5]
                ]
                layers.append(label)
            }
        }
        var style: [String: Any] = ["version":8,"name":"HUNT MAP KZ Protomaps",
                                   "sources":sources,"layers":layers]
        if canLabel {
            style["glyphs"] = local ? ProtomapsAssets.glyphs(in: folder) :
                "https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf"
            style["sprite"] = local ? ProtomapsAssets.sprite(in: folder) :
                "https://protomaps.github.io/basemaps-assets/sprites/v4/light"
        }
        guard let data = try? JSONSerialization.data(withJSONObject:style,options:[.sortedKeys]) else { return nil }
        let url = folder.appendingPathComponent(local ? "protomaps-offline-style.json" : "protomaps-online-style.json")
        do { try data.write(to:url,options:.atomic); return url }
        catch { return nil }
    }
}
