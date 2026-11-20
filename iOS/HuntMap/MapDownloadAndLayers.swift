
import SwiftUI
import HuntCore

/// Offline OSM extracts are downloaded from Overpass and displayed immediately.
/// This is a feature overlay, not a complete raster/vector basemap.
struct QuickMapDownloadSheet: View {
    let point: GeoPoint?
    @ObservedObject var osm: NativeOfflineOSM
    @ObservedObject var tiles: OfflineTileStore
    let onOpenLibrary: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var radius = 1500
    @State private var name = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Скачать дороги и тропы", systemImage: "arrow.down.circle.fill")
                            .font(.title2.bold())
                        Text("Нажмите «Скачать». Данные OpenStreetMap сохранятся на iPhone и сразу появятся на карте. Интернет нужен только для загрузки.")
                            .foregroundStyle(.secondary)
                        if let point {
                            Text(String(format: "Центр: %.5f, %.5f", point.latitude, point.longitude))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        } else {
                            Label("Сначала включите GPS или выберите точку на карте", systemImage: "location.slash")
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Площадь загрузки").font(.headline)
                        Picker("Радиус", selection: $radius) {
                            Text("500 м").tag(500)
                            Text("1 км").tag(1000)
                            Text("1,5 км").tag(1500)
                            Text("2,5 км").tag(2500)
                            Text("5 км").tag(5000)
                            Text("10 км").tag(10000)
                        }
                        .pickerStyle(.menu)
                        TextField("Название района (необязательно)", text: $name)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            guard let point else { return }
                            let selectedRadius = radius
                            let selectedName = name
                            Task { await osm.download(around: point, radiusMeters: selectedRadius, title: selectedName) }
                        } label: {
                            HStack {
                                Spacer()
                                if osm.busy { ProgressView().tint(.white) }
                                Image(systemName: "arrow.down.to.line.compact")
                                Text(osm.busy ? "Загружаем…" : "Скачать и показать на карте")
                                Spacer()
                            }
                            .font(.headline)
                            .padding(14)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .background(point == nil || osm.busy ? Color.gray : Color.orange,
                                    in: RoundedRectangle(cornerRadius: 13))
                        .disabled(point == nil || osm.busy)
                        Text(osm.status)
                            .font(.footnote)
                            .foregroundStyle(osm.lastDownloadError == nil ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                        if let error = osm.lastDownloadError {
                            Label("Загрузка не удалась", systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline.bold()).foregroundStyle(.red)
                            Text(error).font(.caption).textSelection(.enabled)
                            if let host = osm.lastServer {
                                Text("Последний сервер: \(host) · HTTP: \(osm.lastHTTPStatus.map(String.init) ?? "нет ответа")")
                                    .font(.caption2).textSelection(.enabled)
                            }
                            ShareLink(item: "HUNT MAP KZ OSM download error: \(error); server: \(osm.lastServer ?? "unknown"); HTTP: \(osm.lastHTTPStatus.map(String.init) ?? "none")") {
                                Label("Поделиться диагностикой загрузки", systemImage: "square.and.arrow.up")
                            }
                            .font(.caption)
                        }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 12) {
                        Label("Карты с моего хостинга", systemImage: "server.rack")
                            .font(.headline)
                        TextField("https://site.kz/maps/catalog.json", text: $tiles.staticCatalogURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.roundedBorder)
                        Button("Получить список карт") {
                            Task { await tiles.loadStaticCatalog() }
                        }
                        .disabled(tiles.busy)
                        ForEach(tiles.staticPacks) { pack in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(pack.name).font(.subheadline.bold())
                                    Text("z\(pack.minzoom)–z\(pack.maxzoom) · \(pack.bytes / 1_048_576) МБ")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Скачать") { Task { await tiles.installStaticPack(pack) } }
                                    .disabled(tiles.busy)
                            }
                        }
                        if tiles.busy { ProgressView(value: tiles.progress) }
                        Text(tiles.message).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Мои офлайн-районы", systemImage: "internaldrive").font(.headline)
                        Text("\(osm.regions.count) районов · \(osm.lines.count) объектов OSM")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ForEach(osm.regions) { region in
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(region.title).font(.subheadline.bold())
                                    Text("\(region.radiusMeters) м · \(region.featureCount) объектов")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { osm.remove(region) } label: {
                                    Image(systemName: "trash")
                                }
                                .disabled(osm.busy)
                            }
                            Divider()
                        }
                        Button("Все установленные карты и импорт MBTiles") {
                            dismiss()
                            onOpenLibrary()
                        }
                        .font(.subheadline.bold())
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                    Text("Источник: © OpenStreetMap contributors, ODbL, через Overpass API. Скачиваются геометрии дорог, троп и водотоков, а не полная подложка. Публичный API ограничивает размер запросов.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Офлайн-карта")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}

struct MapLayersSheet: View {
    @Binding var mapStyle: String
    @Binding var online: Bool
    @Binding var grounds: Bool
    @Binding var markers: Bool
    @Binding var roads: Bool
    @Binding var track: Bool
    @Binding var gps: Bool
    @Binding var grid: Bool
    let onDownload: () -> Void
    let onLibrary: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Картографическая подложка").font(.headline)
                    Text("Выбор оформления изменяет настоящую карту, а переключатели ниже управляют отдельными слоями.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        styleCard("Туристическая", subtitle: "Liberty", symbol: "mountain.2", key: "liberty")
                        styleCard("Контрастная", subtitle: "Bright", symbol: "map", key: "bright")
                        styleCard("Светлая", subtitle: "Positron", symbol: "square.3.layers.3d", key: "positron")
                    }
                    Toggle(isOn: $online) {
                        Label("Онлайн-подложка", systemImage: "network")
                    }
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
                    Text("Для офлайна дождитесь 100% загрузки пакета MapLibre. Незавершённый пакет не считается установленной картой. Дороги Overpass не заменяют подложку.")
                        .font(.caption).foregroundStyle(.secondary)

                    Text("Объекты на карте").font(.headline)
                    VStack(spacing: 0) {
                        layerToggle("Границы охотугодий", "square.dashed", binding: $grounds)
                        Divider().padding(.leading, 48)
                        layerToggle("Загруженные дороги и тропы OSM", "point.topleft.down.to.point.bottomright.curvepath", binding: $roads)
                        Divider().padding(.leading, 48)
                        layerToggle("Маркеры и машина", "mappin.circle", binding: $markers)
                        Divider().padding(.leading, 48)
                        layerToggle("Маршрут", "point.topleft.down.curvedto.point.bottomright.up", binding: $track)
                        Divider().padding(.leading, 48)
                        layerToggle("Моё местоположение", "location", binding: $gps)
                        Divider().padding(.leading, 48)
                        layerToggle("Покрытие загрузок", "square.grid.3x3", binding: $grid)
                    }
                    .padding(.horizontal, 14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
                    HStack(spacing: 10) {
                        Button {
                            dismiss()
                            onDownload()
                        } label: {
                            Label("Скачать район", systemImage: "arrow.down.circle")
                                .frame(maxWidth: .infinity).padding(13)
                        }
                        .buttonStyle(.borderedProminent).tint(.orange)
                        Button {
                            dismiss()
                            onLibrary()
                        } label: {
                            Label("Мои карты", systemImage: "internaldrive")
                                .frame(maxWidth: .infinity).padding(13)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Карта и слои")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }

    private func styleCard(_ title: String, subtitle: String, symbol: String, key: String) -> some View {
        Button {
            mapStyle = key
            online = true
        } label: {
            VStack(spacing: 9) {
                Image(systemName: symbol).font(.title2)
                Text(title).font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.8)
                Text(subtitle).font(.caption2)
            }
            .frame(maxWidth: .infinity).frame(height: 92)
            .foregroundStyle(mapStyle == key && online ? Color.orange : Color.primary)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(mapStyle == key && online ? Color.orange : Color.clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
    }

    private func layerToggle(_ name: String, _ icon: String, binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Label(name, systemImage: icon).font(.subheadline)
        }
        .padding(.vertical, 11)
        .tint(.orange)
    }
}
