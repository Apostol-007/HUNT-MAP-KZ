import SwiftUI
import HuntCore
import LocalAuthentication
import UniformTypeIdentifiers

extension GeoZone {
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
    @State private var search = ""
    @State private var importing = false
    @State private var error = ""
    @State private var admin = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Охотугодья · \(model.zones.count)").font(.title2.bold())
            TextField("Поиск по названию", text: $search).textFieldStyle(.roundedBorder)
            Text(model.groundMonitorStatus).font(.caption).foregroundStyle(.green)
            if model.monitoredGroundID != nil { Button("Отключить контроль") { model.stopGroundMonitor() } }
            Button("Импорт GeoJSON") { importing = true }
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
                    VStack(alignment: .leading, spacing: 8) {
                        Button { onDetails(ground) } label: { Label(ground.name, systemImage: "leaf.fill").font(.headline) }
                        HStack {
                            Button("Маршрут") { onRoute(ground) }
                            Button("На карте") { onMap(ground) }
                            if let link = ground.groundRouteLink { ShareLink(item: link) { Image(systemName: "square.and.arrow.up") } }
                        }.font(.caption)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
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
                    Text(current.name).font(.headline)
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
