import SwiftUI
import HuntCore

enum MeasurementKind: String, CaseIterable, Codable {
    case distance = "Расстояние", area = "Площадь", bearing = "Азимут", boundary = "До границы"
}
struct SavedMeasurement: Codable {
    let id: UUID
    let kind: MeasurementKind
    let points: [GeoPoint]
    let date: Date
    let value: Double
}
struct MeasurementArchive {
    private var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("measurements.json")
    }
    func save(_ item: SavedMeasurement) throws {
        var all: [SavedMeasurement] = []
        if FileManager.default.fileExists(atPath: url.path) {
            all = try JSONDecoder().decode([SavedMeasurement].self, from: Data(contentsOf: url))
        }
        all.append(item)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).write(to: url, options: .atomic)
    }
}
struct MeasurementPanel: View {
    let kind: MeasurementKind
    @Binding var points: [GeoPoint]
    @Binding var moveIndex: Int?
    let archive: MeasurementArchive
    let boundaryDistance: Double?
    let onClose: () -> Void
    @State private var message = ""
    private var value: Double? {
        switch kind {
        case .distance: return points.count >= 2 ? FieldMeasurements.distance(points) : nil
        case .area: return FieldMeasurements.area(points)
        case .bearing: return points.count >= 2 ? FieldMeasurements.bearing(points[0], points[points.count-1]) : nil
        case .boundary: return boundaryDistance
        }
    }
    private var display: String {
        guard let value else { return "—" }
        switch kind {
        case .area: return String(format: "%.2f га",value/10000)
        case .bearing: return String(format: "%.1f°",value)
        default: return value >= 1000 ? String(format: "%.2f км",value/1000) : String(format: "%.1f м",value)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(kind.rawValue).font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").frame(width:44,height:44) }
            }
            Text(display).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(hint).font(.caption).foregroundStyle(HuntReference.muted)
            HStack(spacing: 8) {
                HuntAction(title: "Отмена", symbol: "arrow.uturn.backward") { if !points.isEmpty { points.removeLast() }; moveIndex = nil }.disabled(points.isEmpty)
                HuntAction(title: "Очистить", symbol: "trash") { points=[]; moveIndex=nil }
                Menu {
                    ForEach(points.indices, id: \.self) { index in
                        Button("Точка \(index+1)") { moveIndex=index }
                    }
                } label: {
                    Label("Сдвиг",systemImage:"move.3d").font(.caption.bold()).foregroundStyle(HuntReference.green).frame(minHeight:44)
                }.disabled(points.isEmpty)
            }
            HStack(spacing: 8) {
                HuntAction(title:"Сохранить",symbol:"square.and.arrow.down") {
                    guard let value else { return }
                    do { try archive.save(SavedMeasurement(id:UUID(),kind:kind,points:points,date:Date(),value:value)); message="Сохранено" }
                    catch { message="Ошибка сохранения: "+error.localizedDescription }
                }.disabled(value == nil || kind == .boundary)
                if !points.isEmpty {
                    ShareLink(item: points.map { String(format:"%.7f,%.7f",$0.latitude,$0.longitude) }.joined(separator:"\n")) {
                        Label("Координаты",systemImage:"square.and.arrow.up").font(.caption.bold()).foregroundStyle(HuntReference.green).frame(minHeight:44)
                    }
                }
            }
            if !message.isEmpty { Text(message).font(.caption) }
        }.huntSurface().accessibilityIdentifier("measurement_panel")
    }
    private var hint: String {
        if let moveIndex { return "Нажмите новое положение точки \(moveIndex+1)." }
        if kind == .boundary { return "Выберите угодье заранее. Нажмите на карту для расчёта расстояния до его контура." }
        if kind == .area && points.count >= 3 && value == nil { return "Некорректный полигон или территория слишком велика. Проверьте пересечения." }
        return "Нажимайте на карту · точек: \(points.count)"
    }
}

struct TrackProfileScreen: View {
    let track: Track
    let onMap: (GeoPoint) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    private struct Sample {
        let point: GeoPoint
        let distance: Double
        let altitude: Double?
    }
    private var samples: [Sample] {
        var result: [Sample] = []
        var distance = 0.0
        var previous: GeoPoint?
        for fix in track.fixes where fix.point.valid {
            if let previous { distance += GeoMath.meters(previous,fix.point) }
            previous=fix.point
            let altitude: Double? = fix.altitude.isFinite && (fix.verticalAccuracy.map { $0 >= 0 && $0 <= 30 } ?? false) ? fix.altitude : nil
            result.append(Sample(point:fix.point,distance:distance,altitude:altitude))
        }
        return result
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                profile(samples)
                    .padding(.horizontal,18).padding(.vertical,14)
            }.background(HuntReference.background.ignoresSafeArea())
                .navigationTitle("Профиль высот").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Готово") { dismiss() } } }
        }
    }
    private func profile(_ values: [Sample]) -> some View {
        let heights = values.compactMap(\.altitude)
        return VStack(alignment:.leading,spacing:12) {
            Text(track.name).font(.headline)
            Text(String(format:"%.2f км · %d точек",track.distanceMeters/1000,track.fixes.count)).font(.caption).foregroundStyle(HuntReference.muted)
            if heights.count >= 2, let low=heights.min(), let high=heights.max() {
                HStack {
                    Text(String(format:"Мин. %.0f м",low))
                    Spacer()
                    Text(String(format:"Макс. %.0f м",high))
                }.font(.caption.bold())
                graph(values,low:low,high:high).frame(height:160)
                Slider(value:Binding(get:{Double(index)},set:{index=Int($0)}),in:0...Double(max(1,values.count-1)),step:1).tint(HuntReference.green)
                if values.indices.contains(index) {
                    let item=values[index]
                    Text(String(format:"%.2f км",item.distance/1000)+" · "+(item.altitude.map{String(format:"%.0f м",$0)} ?? "нет валидной высоты")).font(.caption)
                    HuntAction(title:"Показать точку на карте",symbol:"map") { onMap(item.point) }
                }
            } else {
                ContentUnavailableView("Нет проверенных высот",systemImage:"mountain.2",description:Text("Для новых записей сохраняется вертикальная точность GPS. Старые записи без неё не используются для профиля."))
            }
        }.huntSurface()
    }
    private func graph(_ values:[Sample],low:Double,high:Double)->some View {
        Canvas { context,size in
            let total=max(1,values.last?.distance ?? 1)
            let span=max(1,high-low)
            var path=Path()
            var active=false
            for sample in values {
                guard let height=sample.altitude else { active=false; continue }
                let p=CGPoint(x:size.width*CGFloat(sample.distance/total),y:size.height*CGFloat(1-(height-low)/span))
                if active { path.addLine(to:p) } else { path.move(to:p); active=true }
            }
            context.stroke(path,with:.color(HuntReference.green),lineWidth:2)
            if values.indices.contains(index) {
                let x=size.width*CGFloat(values[index].distance/total)
                var cursor=Path(); cursor.move(to:CGPoint(x:x,y:0));cursor.addLine(to:CGPoint(x:x,y:size.height))
                context.stroke(cursor,with:.color(.white.opacity(0.65)),lineWidth:1)
            }
        }
    }
}
