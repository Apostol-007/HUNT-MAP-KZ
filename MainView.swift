import SwiftUI
import HuntCore
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var model:FieldModel
    @StateObject private var tileStore = OfflineTileStore()
    @StateObject private var wildlifeStore = WildlifeStore()
    @StateObject private var wildlifeUpdater = WildlifeUpdater()
    @StateObject private var boundaryDownloader = BoundaryDownloader()
    @State private var boundaryGroundID = ""
    @State private var directGeoJSONURL = ""
    @State private var wildlifeServer = "https://example.org"
    @State private var wildlifeGround = ""
    @State private var wildlifeImportShown = false
    @State private var wildlifeSearch = ""
    @State private var selectedScope = "ground"
    @State private var scopeID = ""
    @State private var tileImportShown=false
    @State private var importShown=false
    @State private var importError:String?
    @State private var showDiagnostics = false
    @State private var showAbout = false
    @State private var selectedZone: GeoZone?
    @State private var tappedMapPoint: GeoPoint?
    @State private var showMapDownload = false
    @State private var publicTaxa: [GBIFTaxon] = []
    @State private var gbifStatus = "Не загружено"
    @State private var loadingGBIF = false
    @AppStorage("hunt.onlineBasemap") private var onlineBasemap = true
    @State private var selectedTab: HuntTab = .map
    // The map is the background of the entire window, NOT a child of TabView.
    // TabView's safe-area and intrinsic sizing previously letterboxed the map.
    private enum HuntTab: String, CaseIterable {
        case map = "Карта", tracks = "Маршруты", markers = "Маркеры"
        case wildlife = "Животные", downloads = "Загрузки"

        var symbol: String {
            switch self {
            case .map: "map.fill"
            case .tracks: "figure.hiking"
            case .markers: "mappin.and.ellipse"
            case .wildlife: "pawprint.fill"
            case .downloads: "arrow.down.circle.fill"
            }
        }
    }

    var body: some View {
        ZStack {
            Group {
                switch selectedTab {
                case .map: mapTab
                case .tracks: tracksTab
                case .markers: markersTab
                case .wildlife: wildlifeTab
                case .downloads: downloadsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // Overlay: does not alter the map's available height.
        .overlay(alignment: .bottom) { floatingNavigation }
        .background(Color.black.ignoresSafeArea())
        .background(ShakeDetector().frame(width: 1, height: 1))
        .onReceive(NotificationCenter.default.publisher(for: .huntShake)) { _ in showDiagnostics = true }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView(model: model, mapCount: tileStore.installed.count, wildlifeCount: wildlifeStore.packs.count, onlineMap: onlineBasemap) }
        .sheet(isPresented: $showAbout) { AboutHuntView() }
    }

    private var floatingNavigation: some View {
        HStack(spacing: 0) {
            ForEach(HuntTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol).font(.system(size: 19, weight: .semibold))
                        Text(tab.rawValue).font(.system(size: 9, weight: .medium))
                            .lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selectedTab == tab ? .orange : .white)
                    .frame(maxWidth: .infinity).frame(height: 50)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
            }
        }
        .padding(.horizontal, 5)
        .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 10)
        .padding(.bottom, 0)
    }

    // All controls are laid out in the SAFE AREA. Only the underlying MapLibre
    // canvas extends under the status bar and home indicator.
    private var mapTab: some View {
        GeometryReader { geometry in
            ZStack {
                OfflineMapView(
                    zones: model.zones, position: model.coordinate, markers: model.markers,
                    track: model.currentTrack, tileFiles: tileStore.paths,
                    tileRevision: tileStore.revision, online: onlineBasemap,
                    selectedZone: $selectedZone, onMapTap: { point in
                        tappedMapPoint = point
                        if tileStore.installed.isEmpty { showMapDownload = true }
                    }
                )
                .ignoresSafeArea(.container, edges: .all)

                VStack(spacing: 0) {
                    headerControls
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 9) {
                            sideControl("magnifyingglass", "Поиск") { selectedTab = .downloads }
                            sideControl("figure.hiking", "Маршруты") { selectedTab = .tracks }
                            sideControl("square.3.layers.3d", "Слои") { onlineBasemap.toggle() }
                            sideControl("pawprint.fill", "Животные") { selectedTab = .wildlife }
                            sideControl("cloud.sun", "Погода") { showAbout = true }
                        }
                        Spacer(minLength: 0)
                        VStack(spacing: 9) {
                            sideControl("location.north.fill", "GPS") { model.requestGPS() }
                            sideControl("location.fill", "Позиция") { model.requestGPS() }
                            sideControl(model.recording ? "stop.circle.fill" : "record.circle", model.recording ? "Стоп" : "Трек") {
                                if model.recording { model.stopTrack() } else { model.startTrack() }
                            }
                            sideControl("mappin.and.ellipse", "Метка") { model.addMarker() }
                            sideControl("square.dashed", "Границы") { selectedTab = .downloads }
                            sideControl("ladybug", "Диагн.") { showDiagnostics = true }
                        }
                    }
                    .padding(.top, 12)
                    Spacer(minLength: 0)
                    if !model.lastWarning.isEmpty && model.lastWarning != "Границы не загружены" {
                        Text(model.lastWarning).font(.caption.bold())
                            .foregroundStyle(.white).padding(8)
                            .background(.orange.opacity(0.92), in: RoundedRectangle(cornerRadius: 10))
                            .padding(.bottom, 8)
                    }
                    if tileStore.installed.isEmpty {
                        Button { showMapDownload = true } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "arrow.down.to.line.compact").font(.title3)
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Карта не загружена").font(.system(size: 13, weight: .bold))
                                    Text("Нажмите для загрузки офлайн-карты")
                                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.8))
                                }
                                Spacer(minLength: 3)
                                Text("Скачать").font(.system(size: 12, weight: .bold))
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(.orange, in: RoundedRectangle(cornerRadius: 11))
                            }
                            .foregroundStyle(.white).padding(10)
                            .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
                        }
                        .buttonStyle(.plain)
                        // Reserve the complete dock height; never draw behind navigation.
                        .padding(.bottom, 69)
                    } else {
                        Color.clear.frame(height: 69)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .sheet(isPresented: $showMapDownload) {
            NavigationStack {
                Form {
                    Section("Выбранная точка") {
                        if let point = tappedMapPoint {
                            Text(String(format: "%.5f, %.5f", point.latitude, point.longitude))
                        } else { Text("Текущая область карты") }
                    }
                    Section("Офлайн-карта") {
                        Text("Для загрузки нужен опубликованный MBTiles-пакет. Выберите пакет в разделе загрузок или импортируйте MBTiles с устройства.")
                        if tileStore.serviceURL.isEmpty {
                            Text("Сервер карт не настроен").foregroundStyle(.orange)
                        }
                        Button("Открыть загрузки и импорт") {
                            showMapDownload = false
                            selectedTab = .downloads
                        }
                    }
                }
                .navigationTitle("Скачать карту")
                .toolbar { ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") { showMapDownload = false }
                }}
            }
        }
        .sheet(item: $selectedZone) { zone in
            GroundDetailsSheet(zone: zone)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var headerControls: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { showAbout = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: "map.fill").foregroundStyle(.orange)
                    Text("HUNT MAP").foregroundStyle(.white)
                    Text("KZ").foregroundStyle(.orange)
                }
                .font(.system(size: 13, weight: .heavy))
                .lineLimit(1).minimumScaleFactor(0.8)
                .padding(.horizontal, 11).frame(height: 39)
                .background(.black.opacity(0.88), in: Capsule())
            }.buttonStyle(.plain)
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Circle().fill(model.coordinate == nil ? .orange : .green).frame(width: 6, height: 6)
                Text("GPS")
            }
            .padding(.horizontal, 9).frame(height: 35)
            .background(.black.opacity(0.88), in: Capsule())
            HStack(spacing: 4) {
                Circle().fill(onlineBasemap ? .green : .orange).frame(width: 6, height: 6)
                Text(onlineBasemap ? "Online" : "Offline")
            }
            .padding(.horizontal, 9).frame(height: 35)
            .background(.black.opacity(0.88), in: Capsule())
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
    }

    private func sideControl(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 20, weight: .semibold))
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(width: 59, height: 54)
            .foregroundStyle(.white)
            .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }

    private func fieldControl(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.title3)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity).frame(minHeight: 44)
        }
        .buttonStyle(.plain).foregroundStyle(.white)
        .accessibilityLabel(title)
    }

    private var tracksTab:some View {
        NavigationStack {
            List {
                if let current=model.currentTrack {Section("Активный маршрут") {trackRow(current);Button(model.paused ? "Продолжить":"Пауза") {model.togglePause()}}}
                Section("История") {ForEach(model.tracks) {trackRow($0)}}
            }.overlay {if model.tracks.isEmpty && model.currentTrack == nil {ContentUnavailableView("Маршрутов пока нет",systemImage:"figure.hiking",description:Text("Начните запись на вкладке Карта"))}}.navigationTitle("Маршруты")
        }
    }
    private func trackRow(_ track:Track)->some View {
        HStack {VStack(alignment:.leading){Text(track.name);Text("\(track.fixes.count) точек · \(Int(track.distanceMeters)) м").font(.caption).foregroundStyle(.secondary)};Spacer();if let url=model.exportGPX(track) {ShareLink(item:url){Image(systemName:"square.and.arrow.up")}}}
    }
    private var markersTab:some View {
        NavigationStack {
            List {ForEach(model.markers) {m in HStack {Image(systemName:"mappin.circle.fill").foregroundStyle(.orange);VStack(alignment:.leading){Text(m.title);Text("\(m.coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(m.coordinate.longitude.formatted(.number.precision(.fractionLength(5))))").font(.caption).foregroundStyle(.secondary)};Spacer();ShareLink(item:"geo:\(m.coordinate.latitude),\(m.coordinate.longitude)"){Image(systemName:"square.and.arrow.up")}}}.onDelete(perform:model.removeMarkers)}
            .toolbar {Button("Добавить",systemImage:"plus") {model.addMarker()}}
            .overlay {if model.markers.isEmpty {ContentUnavailableView("Маркеров пока нет",systemImage:"mappin",description:Text("Добавьте метку по GPS"))}}.navigationTitle("Маркеры")
        }
    }
    private var wildlifeTab:some View {
        NavigationStack {
            List {
                Section {
                    Text("Данные о животных не означают разрешение на охоту. Источники импортированных пакетов не проверяются приложением автоматически.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Получить виды из GBIF · Казахстан", systemImage: "globe.asia.australia") {
                        Task {
                            loadingGBIF = true
                            defer { loadingGBIF = false }
                            do {
                                publicTaxa = try await GBIFDiscovery.fetchKazakhstan()
                                gbifStatus = "Получено названий: \(publicTaxa.count). Это наблюдения, а не список видов угодья"
                            } catch { gbifStatus = "Ошибка GBIF: \(error.localizedDescription)" }
                        }
                    }.disabled(loadingGBIF)
                    Text(gbifStatus).font(.caption).foregroundStyle(.secondary)
                    ForEach(publicTaxa) { taxon in
                        Text(taxon.name).font(.subheadline)
                    }
                    Button("Импортировать каталог JSON", systemImage: "square.and.arrow.down") {
                        wildlifeImportShown = true
                    }
                    Text(wildlifeStore.message).font(.caption).foregroundStyle(.secondary)
                    TextField("HTTPS-адрес сервера", text: $wildlifeServer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("ID угодья из проверенного источника", text: $wildlifeGround)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Проверить обновления", systemImage: "arrow.clockwise") {
                        Task { await wildlifeUpdater.check(server: wildlifeServer, groundID: wildlifeGround) }
                    }.disabled(wildlifeUpdater.busy)
                    Text(wildlifeUpdater.status).font(.caption).foregroundStyle(.secondary)
                    ForEach(wildlifeUpdater.candidates) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Версия: \(item.pack_id)").font(.subheadline)
                                Text("\(item.taxa_count) видов · \(item.generated_at)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Скачать") {
                                Task { await wildlifeUpdater.install(item, server: wildlifeServer, store: wildlifeStore) }
                            }.disabled(wildlifeUpdater.busy)
                        }
                    }
                }
                ForEach(Array(wildlifeStore.packs.enumerated()), id: \.offset) { index, pack in
                    Section {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Территория: \(pack.ground_id)").font(.headline)
                                Text("Источник: \(pack.source) · \(pack.license)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Дата набора: \(pack.generated_at)").font(.caption2)
                            }
                            Spacer()
                            Button(role: .destructive) { wildlifeStore.remove(at: index) } label: {
                                Image(systemName: "trash")
                            }
                        }
                    } header: { Text("Каталог \(index + 1)") }
                    Section("Виды · \(pack.taxa.count)") {
                        ForEach(pack.taxa.filter { wildlifeSearch.isEmpty ||
                            $0.scientific_name.localizedCaseInsensitiveContains(wildlifeSearch) ||
                            ($0.name_ru?.localizedCaseInsensitiveContains(wildlifeSearch) ?? false) ||
                            ($0.name_kk?.localizedCaseInsensitiveContains(wildlifeSearch) ?? false)
                        }) { taxon in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(taxon.name_ru ?? taxon.name_kk ?? taxon.scientific_name).font(.headline)
                                Text(taxon.scientific_name).italic().font(.caption)
                                Text("Статус: \(wildlifeLabel(taxon.category)) · свидетельств: \(taxon.evidence_count)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let date = taxon.latest_evidence_at { Text("Последнее свидетельство: \(date)").font(.caption2) }
                                if let source = taxon.source_record_url, let url = URL(string: source) {
                                    Link("Исходная запись", destination: url).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $wildlifeSearch, prompt: "Русское, казахское или научное название")
            .navigationTitle("Животные")
            .fileImporter(isPresented: $wildlifeImportShown, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): wildlifeStore.importFile(url)
                case .failure(let error): wildlifeStore.message = error.localizedDescription
                }
            }
        }
    }
    private func wildlifeLabel(_ category: String) -> String {
        switch category {
        case "confirmed": "подтверждено источником"
        case "probable": "вероятно"
        case "historical": "историческое"
        default: "нет данных"
        }
    }
    private var downloadsTab:some View {
        NavigationStack {
            Form {
                Section("Картографическая подложка") {
                    Toggle("Онлайн-карта OpenFreeMap", isOn: $onlineBasemap)
                    Text("Онлайн-режим показывает дороги, тропы и объекты при наличии интернета. Отключите его для строгого офлайна. Онлайн-тайлы не скачиваются массово для офлайн-использования.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("О приложении и диагностика") {
                    Button("О приложении") { showAbout = true }
                    Button("Диагностика / сохранить / отправить в ChatGPT") { showDiagnostics = true }
                    Button("Запросить фоновое разрешение GPS") { model.requestBackgroundGPS() }
                    Text("Также откройте диагностику, встряхнув iPhone.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Загрузка опубликованных границ") {
                    TextField("ID угодья из каталога вашего сервера", text: $boundaryGroundID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Загрузить GeoJSON с сервера") {
                        Task { await boundaryDownloader.fetch(server: tileStore.serviceURL, groundID: boundaryGroundID, model: model) }
                    }.disabled(boundaryDownloader.busy || boundaryGroundID.isEmpty)
                    Text(boundaryDownloader.message).font(.caption).foregroundStyle(.secondary)
                }
                Section("Загрузить GeoJSON напрямую") {
                    TextField("https://.../grounds.geojson", text: $directGeoJSONURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Загрузить границы из HTTPS GeoJSON", systemImage: "globe") {
                        Task { await boundaryDownloader.fetchGeoJSON(urlString: directGeoJSONURL, model: model) }
                    }.disabled(boundaryDownloader.busy || directGeoJSONURL.isEmpty)
                    Text("Источник должен разрешать загрузку и повторное использование. Поддерживаются FeatureCollection и Feature с Polygon/MultiPolygon. Сохраняются все простые поля properties.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Открытые источники границ") {
                    Link("Государственные геоданные Казахстана (проверяйте права)", destination: URL(string: "https://data.egov.kz/")!)
                    Link("Tabigat: исходные данные и карта", destination: URL(string: "https://tabigat.gov.kz/")!)
                    Text("Автоматическая загрузка официальных границ не включена: требуется подтверждённый машиночитаемый адрес и разрешение. GeoJSON импортируется отдельно.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Сервер карт") {
                    TextField("https://maps.example.kz", text: $tileStore.serviceURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Только HTTPS. В публичном каталоге нет проверенных охотугодий: сервер должен быть настроен и наполнен правомерными данными.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Режим загрузки") {
                    Picker("Масштаб пакета", selection: $selectedScope) {
                        Text("Область").tag("region")
                        Text("Охотугодье").tag("ground")
                        Text("Казахстан").tag("country")
                    }.pickerStyle(.segmented)
                    TextField(selectedScope == "country" ? "KZ" : "ID области / угодья", text: $scopeID)
                        .textInputAutocapitalization(.never)
                    Button("Найти пакеты") {
                        Task { await tileStore.fetch(scope: selectedScope, id: selectedScope == "country" ? "KZ" : scopeID) }
                    }.disabled(tileStore.busy || (selectedScope != "country" && scopeID.isEmpty))
                    ForEach(tileStore.available) { pack in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pack.pack_id).font(.headline)
                            Text("\(ByteCountFormatter.string(fromByteCount: pack.size_bytes, countStyle: .file)) · \(pack.source_version) · \(pack.license)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Скачать / продолжить (SHA-256)") { Task { await tileStore.install(pack) } }
                                .disabled(tileStore.busy)
                        }
                    }
                }
                Section("Импорт без сервера") {
                    Button("Импортировать растровый MBTiles", systemImage: "square.and.arrow.down") { tileImportShown = true }
                    Text("Только ваши файлы, которые законно разрешено копировать. Лицензия и границы автоматически не подтверждаются.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Установленные карты") {
                    if tileStore.installed.isEmpty { Text("Офлайн-карты пока отсутствуют") }
                    ForEach(tileStore.installed) { pack in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pack.pack_id)
                                Text("\(pack.license) · \(pack.verified ? "источник проверен" : "источник не подтверждён")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { tileStore.remove(pack) } label: { Image(systemName: "trash") }
                        }
                    }
                }
                Section("Статус") {
                    if tileStore.busy { ProgressView(value: tileStore.progress) }
                    Text(tileStore.message)
                    LabeledContent("Картографических пакетов", value: String(tileStore.installed.count))
                    LabeledContent("Границ", value: String(model.zones.count))
                    LabeledContent("Каталогов животных", value: String(wildlifeStore.packs.count))
                }
                Section("Локальный GeoJSON") {Button("Импортировать границы GeoJSON",systemImage:"square.and.arrow.down") {importShown=true};if let importError {Text(importError).foregroundStyle(.red)}}
                Section("Тестирование") {Button("Показать демо-полигон") {model.loadDemoZones()};Text("Демонстрационный полигон создан искусственно. Он не является охотугодьем.").font(.caption).foregroundStyle(.secondary)}
                Section("Ограничения") {
                    Text("MapLibre использует локальный стиль без интернет-источников и файлы MBTiles. Отсутствие сетевых запросов необходимо подтвердить сетевым тестом на физическом iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Загрузки").fileImporter(isPresented: $tileImportShown, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): Task { await tileStore.importLocal(url) }
                case .failure(let error): importError = error.localizedDescription
                }
            }.fileImporter(isPresented:$importShown,allowedContentTypes:[.json]) { result in
                do {model.setImportedZones(try GeoJSONImport.load(result.get()));importError=nil} catch {importError=error.localizedDescription}
            }
        }
    }
}

struct OfflineCanvas:View {
    let zones:[GeoZone];let position:GeoPoint?;let markers:[Marker];let track:Track?
    @State private var scale=1.0
    @State private var offset:CGSize = .zero
    var body:some View {
        GeometryReader { geo in
            Canvas {context,size in
                let center=position ?? GeoPoint(43.26,76.90)
                let span=0.12/scale
                func screen(_ p:GeoPoint)->CGPoint {
                    CGPoint(x:size.width/2+(p.longitude-center.longitude)/span*size.width+offset.width,y:size.height/2-(p.latitude-center.latitude)/span*size.height+offset.height)
                }
                for zone in zones {
                    for poly in zone.polygons {
                        for ring in poly.rings {
                            guard let first=ring.first else {continue}
                            var path=Path();path.move(to:screen(first))
                            for p in ring.dropFirst() {path.addLine(to:screen(p))};path.closeSubpath()
                            context.stroke(path,with:.color(zone.verified ? .orange : .yellow),lineWidth:3)
                        }
                    }
                }
                if let track,let first=track.fixes.first {var path=Path();path.move(to:screen(first.point));for fix in track.fixes.dropFirst() {path.addLine(to:screen(fix.point))};context.stroke(path,with:.color(.green),lineWidth:3)}
                for m in markers {let p=screen(m.coordinate);context.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.orange))}
                if let position {let p=screen(position);context.fill(Path(ellipseIn:CGRect(x:p.x-7,y:p.y-7,width:14,height:14)),with:.color(.blue));context.stroke(Path(ellipseIn:CGRect(x:p.x-8,y:p.y-8,width:16,height:16)),with:.color(.white),lineWidth:2)}
            }
            .overlay(alignment:.topLeading) {VStack(alignment:.leading){Text("СХЕМА · БЕЗ ПОДЛОЖКИ").font(.caption.bold());Text("Не навигационная топокарта").font(.caption2)}.foregroundStyle(.white).padding(10).background(.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius:8)).padding(10)}
            .overlay(alignment:.bottomTrailing) {VStack {Button {scale=min(20,scale*1.5)} label:{Image(systemName:"plus")};Button {scale=max(0.5,scale/1.5)} label:{Image(systemName:"minus")}}.buttonStyle(.borderedProminent).padding(12)}
            .gesture(DragGesture().onChanged {offset=$0.translation}.onEnded {_ in offset = .zero})
        }
    }
}


/// All original fields are presented, rather than a hardcoded mock of one hunting ground.
private struct GroundDetailsSheet: View {
    let zone: GeoZone
    @Environment(\.dismiss) private var dismiss
    private var fields: [(key: String, value: String)] {
        (zone.attributes ?? [:]).map { (key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Общая информация") {
                    LabeledContent("Название", value: zone.name)
                    LabeledContent("Тип", value: zone.kind == .protectedArea ? "Охраняемая территория" : "Охотничье хозяйство")
                    LabeledContent("Достоверность", value: zone.verified ? "Верифицировано" : "Не подтверждено")
                    LabeledContent("Источник", value: zone.source)
                }
                Section("Все атрибуты источника · \(fields.count)") {
                    if fields.isEmpty {
                        Text("В GeoJSON отсутствуют атрибуты хозяйства. Их нельзя восстановить по одной геометрии.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(fields.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(fields[index].key).font(.caption).foregroundStyle(.secondary)
                            Text(fields[index].value.isEmpty ? "Нет данных" : fields[index].value)
                                .font(.body).textSelection(.enabled)
                        }.padding(.vertical, 3)
                    }
                }
                Section {
                    Text("Данные информационные. Актуальность границ, договоров и разрешений необходимо проверить по первоисточнику.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(zone.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
        }
    }
}
