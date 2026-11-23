import SwiftUI

/// True tile downloads for selected WGS84 grid cells. GeoJSON is not the basemap.
struct OfflineGridDownloadSheet: View {
    @ObservedObject var hosting: HostingOfflineDownloads
    @ObservedObject var tiles: OfflineTileStore
    @ObservedObject var nativePacks: NativeOfflinePackStore
    @Binding var selected: Set<String>
    let step: Double
    @Environment(\.dismiss) private var dismiss
    @State private var minZoom = 9
    @State private var maxZoom = 14

    private var cells: [OfflineGridCell] {
        selected.sorted().compactMap { OfflineGridCell(id: $0, step: step) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Полноценная карта") {
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
        }
    }
}
