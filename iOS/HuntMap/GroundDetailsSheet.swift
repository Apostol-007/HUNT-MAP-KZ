import SwiftUI
import HuntCore
import LocalAuthentication
import UniformTypeIdentifiers

extension GeoZone {
    private func groundField(_ keys: [String]) -> String? {
        for key in keys {
            guard let value = attributes?[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty, value != "[]" else { continue }
            if let data = value.data(using: .utf8), let items = try? JSONDecoder().decode([String].self, from: data) {
                if !items.isEmpty { return items.joined(separator: ", ") }
            } else { return value }
        }
        return nil
    }
    var groundRegion: String { groundField(["region", "district", "region_name", "oblast"]) ?? "Регион не указан" }
    var groundAnimals: String { groundField(["animals", "animals_mentioned_in_sources"]) ?? "Нет данных о животных" }
    var groundPhone: String { groundField(["phone", "phones_published"]) ?? "Контакты не указаны" }
    var groundDescription: String? { groundField(["description", "research_notes", "organization", "operators_reported"]) }
    var groundAreaLabel: String {
        if let area = groundField(["area_ha", "area_hectares"]) { return area + " га · источник" }
        // Spherical ring area, subtract holes. This is coverage area, not official land area.
        func area(_ ring: [GeoPoint]) -> Double {
            guard ring.count >= 3 else { return 0 }
            var sum = 0.0
            for i in ring.indices {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let delta = (b.longitude - a.longitude) * .pi / 180
                sum += delta * (sin(a.latitude * .pi / 180) + sin(b.latitude * .pi / 180))
            }
            return abs(sum) * 6_371_000.0 * 6_371_000.0 / 2
        }
        let squareMeters = polygons.reduce(0.0) { total, polygon in
            guard let outer = polygon.rings.first else { return total }
            return total + max(0, area(outer) - polygon.rings.dropFirst().reduce(0.0) { $0 + area($1) })
        }
        return (squareMeters / 10_000).formatted(.number.precision(.fractionLength(0))) + " га · площадь контура"
    }
    var groundCenter: GeoPoint? {
        let points = polygons.flatMap { $0.rings.first ?? [] }
        guard let south = points.map(\.latitude).min(), let north = points.map(\.latitude).max(),
              let west = points.map(\.longitude).min(), let east = points.map(\.longitude).max() else { return nil }
        return GeoPoint((south + north) / 2, (west + east) / 2)
    }

    var groundDestination: GeoPoint? {
        if let a = attributes?["entrance_lat"], let b = attributes?["entrance_lon"],
           let lat = Double(a), let lon = Double(b) {
            let point = GeoPoint(lat, lon)
            if point.valid { return point }
        }
        return polygons.first?.rings.first?.first
    }
    var groundRouteLink: String? {
        guard let p = groundDestination else { return nil }
        return "https://www.google.com/maps/dir/?api=1&destination=\(p.latitude),\(p.longitude)"
    }
}

struct GroundsCatalogView: View {
    @ObservedObject var model: FieldModel
    let onDetails: (GeoZone) -> Void
    let onMap: (GeoZone) -> Void
    let onRoute: (GeoZone) -> Void
    var onOpenMap: () -> Void = {}
    @State private var search = ""
    @State private var importing = false
    @State private var error = ""
    @State private var admin = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Охотугодья").font(.system(size: 28, weight: .bold))
                    Text("\(model.zones.count) территорий · офлайн").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { onOpenMap() } label: {
                    Label("Карта", systemImage: "map").font(.subheadline.bold()).padding(12)
                        .background(Color.green.opacity(0.12), in: Capsule())
                }.foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.52))
            }
            Text("Контуры покрытия, не официальные границы").font(.caption).foregroundStyle(.orange)
            TextField("Поиск по названию", text: $search).textFieldStyle(.roundedBorder)
            Text(model.groundMonitorStatus).font(.caption).foregroundStyle(.green)
            if model.monitoredGroundID != nil { Button("Отключить контроль") { model.stopGroundMonitor() } }
            if model.zones.isEmpty { Text("Загрузка встроенного каталога…").font(.caption) }
            Button("Импорт дополнительного GeoJSON") { importing = true }
            Button("Локальный администратор") { unlock() }
            if admin {
                Button("Добавить угодья из GeoJSON") { importing = true }
                if let file = GroundsExport.file(model.zones) {
                    ShareLink(item: file) { Label("Экспорт / резервная копия GeoJSON", systemImage: "square.and.arrow.up") }
                }
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(model.zones.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }) { ground in
                    GroundCatalogCard(ground: ground, onDetails: { onDetails(ground) }, onMap: { onMap(ground) }, onRoute: { onRoute(ground) })
                }
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "geojson") ?? .json, .json]) { result in
            do {
                let url = try result.get()
                Task {
                    do {
                        let items = try await Task.detached { try GeoJSONImport.load(url) }.value
                        model.setImportedZones(items)
                        error = ""
                    } catch { self.error = error.localizedDescription }
                }
            } catch { self.error = error.localizedDescription }
        }
    }
    private func unlock() {
        let context = LAContext()
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Локальное управление базой угодий") { success, _ in
            Task { @MainActor in admin = success; if !success { error = "Доступ не подтверждён" } }
        }
    }
}

private struct GroundCatalogCard: View {
    let ground: GeoZone
    let onDetails: () -> Void
    let onMap: () -> Void
    let onRoute: () -> Void
    private let accent = Color(red: 0.35, green: 0.78, blue: 0.52)
    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            Button(action: onDetails) {
                HStack(alignment: .top) {
                    Text(ground.name).font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(accent)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            field("map", ground.groundRegion)
            field("pawprint", ground.groundAnimals)
            field("square.dashed", ground.groundAreaLabel)
            field("phone.fill", ground.groundPhone)
            if let description = ground.groundDescription {
                field("info.circle", description)
            }
            Divider().overlay(accent.opacity(0.22))
            HStack(spacing: 8) {
                Button(action: onRoute) { Label("Маршрут", systemImage: "location.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                Button(action: onMap) { Label("На карте", systemImage: "map.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).tint(accent)
                if let link = ground.groundRouteLink {
                    ShareLink(item: link) { Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44) }
                        .foregroundStyle(accent).accessibilityLabel("Поделиться маршрутом")
                }
            }.font(.caption.bold()).controlSize(.large)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.075, green: 0.20, blue: 0.18), in: RoundedRectangle(cornerRadius: 24))
        .environment(\.colorScheme, .dark)
    }
    private func field(_ symbol: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                .foregroundStyle(accent).frame(width: 25)
            Text(value).font(.system(size: 15)).foregroundStyle(.white.opacity(0.93))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

enum GroundsExport {
    static func file(_ zones: [GeoZone]) -> URL? {
        let features: [[String: Any]] = zones.map { zone in
            var props = zone.attributes ?? [:]
            props["name"] = zone.name
            props["ground_id"] = zone.id
            props["kind"] = zone.kind.rawValue
            let coords = zone.polygons.map { $0.rings.map { $0.map { [$0.longitude, $0.latitude] } } }
            return ["type": "Feature", "properties": props, "geometry": ["type": "MultiPolygon", "coordinates": coords]]
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HUNT_GROUNDS.geojson")
        do {
            let data = try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features], options: [.sortedKeys])
            try data.write(to: url, options: .atomic)
            return url
        } catch { return nil }
    }
}

struct GroundDetailsSheet: View {
    let zone: GeoZone
    @ObservedObject var model: FieldModel
    let onMap: (GeoZone) -> Void
    let onRoute: (GeoZone) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var error = ""
    private var current: GeoZone { model.zones.first(where: { $0.id == zone.id }) ?? zone }
    var body: some View {
        NavigationStack {
            List {
                Section("Информация") {
                    GroundCatalogCard(ground: current, onDetails: {}, onMap: { onMap(current) }, onRoute: { onRoute(current) })
                    Text(current.source).font(.caption)
                    Text("Границы юридически не подтверждены").foregroundStyle(.orange)
                }
                Section("Действия") {
                    Button("Построить маршрут") { onRoute(current) }
                    Button("Показать на карте") { onMap(current) }
                    if let link = current.groundRouteLink { ShareLink(item: link) { Label("Поделиться маршрутом", systemImage: "square.and.arrow.up") } }
                    Button(model.monitoredGroundID == current.id ? "Остановить контроль" : "Я в охотугодье") {
                        if model.monitoredGroundID == current.id { model.stopGroundMonitor() }
                        else { model.startGroundMonitor(current) }
                    }
                    Text(model.groundMonitorStatus).font(.caption)
                    Button("Разрешить фоновый GPS") { model.requestBackgroundGPS() }
                }
                Section("Все данные источника") {
                    ForEach((current.attributes ?? [:]).keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading) {
                            Text(key).font(.caption).foregroundStyle(.secondary)
                            Text(current.attributes?[key] ?? "Нет данных").textSelection(.enabled)
                        }
                    }
                }
                Section("Администрирование") {
                    Button("Редактировать (локально)") {
                        let context = LAContext()
                        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Редактирование охотугодья") { success, _ in
                            Task { @MainActor in editing = success; if !success { error = "Доступ не подтверждён" } }
                        }
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.orange) }
                }
            }.navigationTitle(current.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
            .sheet(isPresented: $editing) { GroundEditor(zone: current, model: model) }
        }
    }
}

struct GroundEditor: View {
    let zone: GeoZone
    @ObservedObject var model: FieldModel
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var values: [String: String]
    @State private var newKey = ""
    @State private var deleting = false
    init(zone: GeoZone, model: FieldModel) {
        self.zone = zone; self.model = model
        _name = State(initialValue: zone.name)
        var attributes = zone.attributes ?? [:]
        for key in ["description", "phone", "email", "website", "organization", "region", "animals", "entrance_lat", "entrance_lon"] where attributes[key] == nil { attributes[key] = "" }
        _values = State(initialValue: attributes)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Название") { TextField("Название", text: $name) }
                Section("Атрибуты") {
                    ForEach(values.keys.sorted(), id: \.self) { key in
                        VStack(alignment: .leading) {
                            Text(key).font(.caption)
                            TextField(key, text: Binding(get: { values[key] ?? "" }, set: { values[key] = $0 }), axis: .vertical)
                        }
                    }
                    TextField("Новый атрибут", text: $newKey)
                    Button("Добавить поле") {
                        let key = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !key.isEmpty && values[key] == nil { values[key] = "" }
                        newKey = ""
                    }
                }
                Button("Удалить угодье", role: .destructive) { deleting = true }
            }.navigationTitle("Редактор угодья")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        values["local_revision"] = UUID().uuidString
                        values["name"] = name
                        model.saveGround(GeoZone(id: zone.id, name: name, kind: zone.kind, verified: false, source: zone.source, polygons: zone.polygons, attributes: values))
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Удалить локальное угодье?", isPresented: $deleting) {
                Button("Удалить", role: .destructive) { model.deleteGround(zone.id); dismiss() }
            }
        }
    }
}
