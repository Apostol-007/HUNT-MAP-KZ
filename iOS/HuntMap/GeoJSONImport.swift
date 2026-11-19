import Foundation
import HuntCore

enum GeoJSONImportError: LocalizedError {
    case invalidFile, invalidGeometry, fileTooLarge
    var errorDescription:String? {
        switch self {case .invalidFile:return "Некорректный GeoJSON";case .invalidGeometry:return "Некорректные координаты или полигоны";case .fileTooLarge:return "Файл больше 20 МБ"}
    }
}

enum GeoJSONImport {
    static func load(_ url:URL)throws->[GeoZone] {
        let access=url.startAccessingSecurityScopedResource()
        defer {if access {url.stopAccessingSecurityScopedResource()}}
        let data=try Data(contentsOf:url)
        guard data.count<=20_000_000 else {throw GeoJSONImportError.fileTooLarge}
        guard let root=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw GeoJSONImportError.invalidFile}
        let features:[[String:Any]]
        if root["type"] as? String == "Feature", let _ = root["geometry"] {
            features=[root]
        } else if root["type"] as? String == "FeatureCollection", let all=root["features"] as? [[String:Any]] {
            features=all
        } else {throw GeoJSONImportError.invalidFile}
        guard !features.isEmpty && features.count<=10_000 else {throw GeoJSONImportError.invalidFile}
        func point(_ raw:Any)->GeoPoint? {
            guard let a=raw as? [NSNumber],a.count>=2 else {return nil}
            let p=GeoPoint(a[1].doubleValue,a[0].doubleValue)
            return p.valid ? p : nil
        }
        func polygon(_ raw:Any)->GeoPolygon? {
            guard let rings=raw as? [Any],!rings.isEmpty,rings.count<=1000 else {return nil}
            var result:[[GeoPoint]]=[]
            for rawRing in rings {
                guard let coords=rawRing as? [Any],coords.count>=4,coords.count<=100_000 else {return nil}
                let parsed=coords.compactMap(point)
                guard parsed.count==coords.count,Set(parsed).count>=3 else {return nil}
                result.append(parsed)
            }
            return GeoPolygon(rings:result)
        }
        return try features.enumerated().map { index, feature in
            guard let geometry=feature["geometry"] as? [String:Any],let kind=geometry["type"] as? String,let raw=geometry["coordinates"] else {throw GeoJSONImportError.invalidGeometry}
            let polygons:[GeoPolygon]
            switch kind {
            case "Polygon":guard let p=polygon(raw) else {throw GeoJSONImportError.invalidGeometry};polygons=[p]
            case "MultiPolygon":guard let all=raw as? [Any],!all.isEmpty,all.count<=1000 else {throw GeoJSONImportError.invalidGeometry}
                let pp=all.compactMap(polygon);guard pp.count==all.count else {throw GeoJSONImportError.invalidGeometry};polygons=pp
            default:throw GeoJSONImportError.invalidGeometry
            }
            let props=feature["properties"] as? [String:Any] ?? [:]
            let name=(props["name"] as? String)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "Полигон \(index+1)"
            let type=(props["kind"] as? String)=="protectedArea" ? ZoneKind.protectedArea : .huntingGround
            let identifier=(props["ground_id"] as? String) ?? "LOCAL-\(index)"
            let origin=(props["source_url"] as? String) ?? "Источник не указан"
            // Neither server operator approval nor client import is legal proof.
            return GeoZone(id:"IMPORTED-\(identifier)-\(index)",name:name,kind:type,verified:false,source:"\(origin) · локальный импорт, юридически не проверено",polygons:polygons)
        }
    }
}
