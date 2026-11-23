import SwiftUI

/// True tile downloads for selected WGS84 grid cells. GeoJSON is not the basemap.
struct OfflineGridDownloadSheet: View {
    @ObservedObject var hosting: HostingOfflineDownloads
    @ObservedObject var tiles: OfflineTileStore
    @ObservedObject var nativePacks: NativeOfflinePackStore
    @ObservedObject var protomaps: ProtomapsOfflineStore
    @Binding var selected: Set<String>
    let step: Double
    @Environment(\.dismiss) private var dismiss
    @State private var minZoom = 9
    @State private var maxZoom = 14
    @State private var address = ""

    private var cells: [OfflineGridCell] {
        selected.sorted().compactMap { OfflineGridCell(id: $0, step: step) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Protomaps · полноценные карты Казахстана") {
                    Text("Карты PMTiles скачиваются с твоего хостинга. Укажи папку с картами или точный URL catalog.json.")
                        .font(.caption)
                    TextField("https://create.web-works.kz/maps/", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .font(.caption.monospaced())
                        .accessibilityIdentifier("protomaps_catalog_address")
                    Button("Проверить хостинг и каталог") {
                        protomaps.setCatalogAddress(address)
                        Task { await protomaps.refresh() }
                    }
                    .disabled(protomaps.busy || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(protomaps.diagnostic)
                        .font(.caption2.monospaced())
                        .foregroundStyle(protomaps.available.isEmpty ? Color.orange : Color.secondary)
                        .textSelection(.enabled)
                    Text("Каталог: \(protomaps.available.count) районов · установлено: \(protomaps.installed.count)")
                    Text(protomaps.status).font(.caption)
                    if protomaps.busy {
                        ProgressView(value: protomaps.progress)
                    }
                    Button("Обновить список карт") { Task { await protomaps.refresh() } }
                        .disabled(protomaps.busy)
                    ForEach(protomaps.available) { pack in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pack.name).font(.caption.bold())
                            Text("\(ByteCountFormatter.string(fromByteCount: pack.bytes, countStyle: .file)) · \(pack.id)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button("Скачать Protomaps по выделенной сетке") {
                        let selectedCells = cells
                        Task { await protomaps.download(cells: selectedCells) }
                    }
                    .disabled(protomaps.busy || cells.isEmpty || protomaps.available.isEmpty)
                    ForEach(protomaps.installed) { item in
                        HStack {
                            Text(item.name).font(.caption)
                            Spacer()
                            Button(role: .destructive) { protomaps.delete(item) } label: {
                                Image(systemName: "trash")
                            }
                            .disabled(protomaps.busy)
                        }
                    }
                    Text(protomaps.assetsReady ? "Подписи RU/KZ и значки сохранены" : "Подписи RU/KZ пока не установлены")
                        .font(.caption2).foregroundStyle(protomaps.assetsReady ? .green : .orange)
                    Button("Скачать подписи и значки") { Task { await protomaps.downloadAssets() } }
                        .disabled(protomaps.busy || protomaps.assetsReady)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Section("Другие источники (совместимость)") {
                    Text("Выбрано клеток: \(cells.count) · размер \(String(format: "%.2f°", step))")
                    Stepper("От масштаба z\(minZoom)", value: $minZoom, in: 5...maxZoom)
                    Stepper("До масштаба z\(maxZoom)", value: $maxZoom, in: minZoom...16)
                    Text("Скачиваются тайлы, стили, подписи и значки выбранного источника, а не дорожной GeoJSON.")
                        .font(.caption)
                    if NativeOfflinePackStore.permittedStyle() == nil {
                        Text("Источник для офлайн-загрузки не настроен. Требуется разрешённый поставщик с HTTPS style.json и параметр HUNT_OFFLINE_STYLE_URL в сборке.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if nativePacks.downloading {
                        ProgressView(value: Double(nativePacks.finishedCells),
                                     total: Double(max(1, nativePacks.totalCells)))
                        Text("Ресурсы: \(nativePacks.progressResources) / \(nativePacks.expectedResources)")
                            .font(.caption.monospacedDigit())
                        Button("Приостановить", role: .destructive) { nativePacks.pause() }
                    } else {
                        Button("Скачать карты выделенных клеток") {
                            nativePacks.begin(cells: cells, minZoom: minZoom, maxZoom: maxZoom)
                        }
                        .disabled(cells.isEmpty || cells.count > 25 ||
                                  NativeOfflinePackStore.permittedStyle() == nil)
                    }
                    Text(nativePacks.status).font(.caption)
                    Text("Пакетов MapLibre на iPhone: \(nativePacks.savedPacks)")
                }
                Section("Уже сохранено") {
                    Text("Растровые MBTiles: \(tiles.installed.count)")
                    Text("Дорожные графы GeoJSON: \(hosting.installedRoutes.count)")
                    Text("Дорожные графы используются для маршрутов пешком и на автомобиле.")
                        .font(.caption)
                }
                Section("Спутниковые снимки") {
                    Text("Поставщик определяет актуальность снимка. Без метаданных даты съёмки нельзя гарантировать 2026 год.")
                        .font(.caption)
                }
            }
            .navigationTitle("Скачать карту по сетке")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } } }
            .task {
                address = protomaps.catalogAddress
                if protomaps.available.isEmpty { await protomaps.refresh() }
            }
        }
    }
}
