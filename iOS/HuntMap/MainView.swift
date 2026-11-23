import SwiftUI
import HuntCore

/// Rebuilt UI: MapLibre remains the root full-screen view. No native TabView,
/// no fixed-height map, no nested NavigationStack around the map.
struct MainView: View {
    @EnvironmentObject private var model: FieldModel
    @StateObject private var maps = OfflineTileStore()
    @StateObject private var animals = WildlifeStore()
    @StateObject private var weather = WeatherService()
    @StateObject private var weatherGrid = WeatherGridService()

    @AppStorage("hunt.onlineBasemap") private var online = true
    @AppStorage("hunt.map.style") private var mapStyle = MapBasemap.bright.rawValue
    @AppStorage("hunt.map.maptilerKey") private var mapTilerKey = ""

    @State private var tab: Tab = .home
    @State private var dataSection: DataSection = .routes
    @State private var serviceSection: ServiceSection = .weather
    @State private var weatherLayer: WeatherMapLayer = .none
    @State private var zone: GeoZone?
    @State private var showLayers = false
    @State private var showWeather = false
    @State private var showWeatherLayers = false
    @State private var showAbout = false
    @State private var showDiagnostics = false
    @State private var showAdvanced = false
    @State private var showGBIF = false
    @State private var taxa: [GBIFTaxon] = []
    @State private var wildlifeError: String?

    private enum Tab: String, CaseIterable {
        case home = "Главная", map = "Карта", data = "Данные", services = "Сервисы", more = "Ещё"
        var icon: String {
            switch self {
            case .home: "house.fill"
            case .map: "map.fill"
            case .data: "square.grid.2x2.fill"
            case .services: "square.stack.3d.up.fill"
            case .more: "ellipsis"
            }
        }
    }
    private enum DataSection: String, CaseIterable { case routes = "Маршруты", markers = "Метки" }
    private enum ServiceSection: String, CaseIterable { case weather = "Погода", wildlife = "Животные" }

    var body: some View {
        ZStack {
            // Keep the expensive MapLibre instance alive when switching tabs.
            // Only controls disappear; the map remains genuinely full-screen.
            mapScreen
                .opacity(tab == .map ? 1 : 0)
                .allowsHitTesting(tab == .map)
            if tab != .map { themedScreen }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) { navigation }
        .background(FBTheme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .background(ShakeDetector().frame(width: 1, height: 1))
        .onReceive(NotificationCenter.default.publisher(for: .huntShake)) { _ in showDiagnostics = true }
        .sheet(isPresented: $showLayers) { layerSheet }
        .sheet(isPresented: $showWeather) {
            WeatherPanel(service: weather, coordinate: model.coordinate, online: online)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showWeatherLayers) {
            WeatherMapSheet(service: weatherGrid, layer: $weatherLayer,
                            coordinate: model.coordinate, online: online)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $zone) { GroundDetailsSheet(zone: $0) }
        .sheet(isPresented: $showDiagnostics) {
            DiagnosticsView(model: model, mapCount: maps.installed.count,
                            wildlifeCount: animals.packs.count, onlineMap: online)
        }
        .sheet(isPresented: $showAbout) { AboutHuntView() }
        .sheet(isPresented: $showAdvanced) { LegacyMainView() .environmentObject(model) }
    }

    // MARK: - Root layout
    private var themedScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                switch tab {
                case .home: homeScreen
                case .data: dataScreen
                case .services: serviceScreen
                case .more: moreScreen
                case .map: EmptyView()
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 15)
            .padding(.bottom, 112)
        }
        .scrollIndicators(.hidden)
        .fbScreenBackground()
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { withAnimation(.easeOut(duration: 0.16)) { tab = item } } label: {
                    FBTabButton(title: item.rawValue, systemImage: item.icon, active: tab == item)
                        .frame(height: 60)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab_\(item.rawValue)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .background(FBTheme.panel.opacity(0.97), in: RoundedRectangle(cornerRadius: 25))
        .overlay(RoundedRectangle(cornerRadius: 25).stroke(FBTheme.stroke, lineWidth: 1))
        .padding(.horizontal, 11)
        .padding(.bottom, 4)
    }

    // MARK: - Home
    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 21) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HUNT MAP KZ").font(.system(size: 26, weight: .heavy, design: .rounded))
                    Text("Охота · Карты · Навигация").font(.subheadline).foregroundStyle(FBTheme.textSecondary)
                }
                Spacer()
                Button { showDiagnostics = true } label: {
                    Image(systemName: "bell.badge")
                        .font(.title3).foregroundStyle(FBTheme.green)
                        .frame(width: 46, height: 46).background(FBTheme.panel2, in: Circle())
                }
                .accessibilityLabel("Диагностика")
            }
            Button { tab = .map } label: {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Color(red: 0.02, green: 0.30, blue: 0.17),
                                            Color(red: 0.02, green: 0.12, blue: 0.12),
                                            FBTheme.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 142, weight: .ultraLight))
                        .foregroundStyle(FBTheme.green.opacity(0.19))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: -12, y: -10)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("КАРТЫ КАЗАХСТАНА").font(.caption.bold()).foregroundStyle(FBTheme.green)
                        Text("Исследуй\nтерритории")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.leading)
                        Text("GPS · Границы · Маршруты")
                            .font(.subheadline).foregroundStyle(FBTheme.textSecondary)
                        Label("Открыть карту", systemImage: "arrow.up.right")
                            .font(.subheadline.bold()).foregroundStyle(FBTheme.green)
                            .padding(.top, 5)
                    }
                    .padding(20)
                }
                .frame(height: 240)
                .background(FBTheme.panel, in: RoundedRectangle(cornerRadius: 25))
                .clipShape(RoundedRectangle(cornerRadius: 25))
                .overlay(RoundedRectangle(cornerRadius: 25).stroke(FBTheme.stroke))
            }
            .buttonStyle(.plain)

            Text("Быстрые действия").font(.title3.bold())
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                actionCard("Открыть карту", subtitle: "Геолокация и слои", icon: "map", tint: FBTheme.green) { tab = .map }
                actionCard("Скачать карты", subtitle: "Офлайн-пакеты", icon: "arrow.down.circle", tint: FBTheme.mint) { showAdvanced = true }
                actionCard("Маршруты", subtitle: "Запись и история", icon: "point.topleft.down.curvedto.point.bottomright.up", tint: FBTheme.cyan) { dataSection = .routes; tab = .data }
                actionCard("Погода", subtitle: "Ветер, давление, осадки", icon: "cloud.sun.fill", tint: FBTheme.green) { serviceSection = .weather; tab = .services }
            }

            VStack(alignment: .leading, spacing: 15) {
                Text("Мои данные").font(.headline)
                HStack(spacing: 0) {
                    statistic("Маршруты", value: model.tracks.count)
                    Spacer()
                    statistic("Метки", value: model.markers.count)
                    Spacer()
                    statistic("Угодья", value: model.zones.count)
                }
            }
            .fbCard()
        }
    }

    private func statistic(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("\(value)").font(.title.bold()).foregroundStyle(FBTheme.green)
            Text(title).font(.caption).foregroundStyle(FBTheme.textSecondary)
        }
    }
    private func actionCard(_ title: String, subtitle: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon).font(.title2.bold()).foregroundStyle(tint)
                    .frame(width: 43, height: 43)
                    .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                    Text(subtitle).font(.caption2).foregroundStyle(FBTheme.textSecondary)
                        .lineLimit(2).frame(minHeight: 29, alignment: .topLeading)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 121)
            .fbCard()
        }.buttonStyle(.plain)
    }

    // MARK: - Full-screen map
    private var mapScreen: some View {
        ZStack {
            OfflineMapView(zones: model.zones, position: model.coordinate,
                           markers: model.markers, track: model.currentTrack,
                           tileFiles: maps.paths, tileRevision: maps.revision,
                           online: online, selectedZone: $zone,
                           weatherGrid: weatherLayer == .none ? nil : weatherGrid.grid,
                           weatherLayer: weatherLayer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .all)
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass").foregroundStyle(FBTheme.green)
                        Text("Карта Казахстана").font(.subheadline.bold())
                        Spacer(minLength: 2)
                        Text(online ? "ОНЛАЙН" : "ОФЛАЙН")
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(online ? FBTheme.green : FBTheme.warning)
                    }
                    .padding(14)
                    .background(FBTheme.panel.opacity(0.93), in: Capsule())
                    Button { showLayers = true } label: {
                        Image(systemName: "square.3.layers.3d")
                            .font(.title3.bold())
                            .foregroundStyle(FBTheme.green)
                            .frame(width: 48, height: 48)
                            .background(FBTheme.panel.opacity(0.93), in: Circle())
                    }
                    .accessibilityLabel("Слои карты")
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                if weatherLayer != .none {
                    Button { showWeatherLayers = true } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "cloud.fill").foregroundStyle(FBTheme.green)
                            Text("\(weatherLayer.rawValue) · \(weatherGrid.forecastLabel)")
                                .font(.caption.bold()).foregroundStyle(.white)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(FBTheme.green)
                        }
                        .padding(12)
                        .background(FBTheme.panel.opacity(0.94), in: RoundedRectangle(cornerRadius: 17))
                    }
                    .padding(.horizontal, 14).padding(.top, 10)
                }
                Spacer(minLength: 0)
                if !model.lastWarning.isEmpty && model.lastWarning != "Границы не загружены" {
                    Label(model.lastWarning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.bold())
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(FBTheme.warning.opacity(0.93), in: RoundedRectangle(cornerRadius: 15))
                        .padding(.horizontal, 14).padding(.bottom, 8)
                }
                HStack(spacing: 10) {
                    mapAction("location.north.fill", "GPS", tint: FBTheme.cyan) { model.requestGPS() }
                    mapAction("mappin.circle.fill", "Метка", tint: FBTheme.green) { model.addMarker() }
                    mapAction(model.recording ? "stop.circle.fill" : "record.circle.fill",
                              model.recording ? "Стоп" : "Запись", tint: model.recording ? FBTheme.danger : FBTheme.mint) {
                        if model.recording { model.stopTrack() } else { model.startTrack() }
                    }
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 86)
            }
        }
    }
    private func mapAction(_ symbol: String, _ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(title).foregroundStyle(.white)
            }
            .font(.subheadline.bold())
            .frame(maxWidth: .infinity)
            .frame(height: 49)
            .background(FBTheme.panel.opacity(0.95), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17).stroke(FBTheme.stroke))
        }
        .buttonStyle(.plain)
    }

    private var layerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Подложка карты").font(.title3.bold())
                    ForEach(MapBasemap.allCases) { style in
                        Button {
                            if style == .satellite && mapTilerKey.isEmpty { return }
                            mapStyle = style.rawValue
                            online = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: style.symbol)
                                    .font(.title3)
                                    .foregroundStyle(FBTheme.green)
                                    .frame(width: 45, height: 45)
                                    .background(FBTheme.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 14))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(style.name).font(.subheadline.bold()).foregroundStyle(.white)
                                    if style == .satellite && mapTilerKey.isEmpty {
                                        Text("Нужен ключ MapTiler").font(.caption).foregroundStyle(FBTheme.warning)
                                    }
                                }
                                Spacer()
                                if mapStyle == style.rawValue {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(FBTheme.green)
                                }
                            }
                            .fbSoftCard()
                        }
                        .buttonStyle(.plain)
                    }
                    Toggle("Онлайн-карта", isOn: $online).tint(FBTheme.green).fbCard()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MapTiler API-ключ").font(.headline)
                        SecureField("Введите ключ для спутника и других карт", text: $mapTilerKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(12)
                            .background(FBTheme.panel2, in: RoundedRectangle(cornerRadius: 13))
                        Text("Без ключа доступны стили OpenFreeMap. Офлайн-карты подключаются только из установленных пакетов. Русские подписи включаются при наличии name:ru.")
                            .font(.caption).foregroundStyle(FBTheme.textSecondary)
                        Text("Данные © OpenStreetMap contributors. Для MapTiler действуют условия его лицензии.")
                            .font(.caption2).foregroundStyle(FBTheme.textSecondary)
                    }.fbCard()
                    Button { showWeatherLayers = true } label: {
                        FBActionPill(title: "Погодные слои", subtitle: "Ветер · Давление · Осадки", icon: "cloud.sun.fill", tint: FBTheme.green)
                    }.buttonStyle(.plain)
                }
                .padding(18)
            }
            .fbScreenBackground()
            .navigationTitle("Слои карты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { showLayers = false } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Routes and markers
    private var dataScreen: some View {
        VStack(alignment: .leading, spacing: 17) {
            pageTitle("Мои данные", subtitle: "Маршруты и сохранённые точки")
            Picker("Раздел", selection: $dataSection) {
                ForEach(DataSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if dataSection == .routes { routesContent } else { markersContent }
        }
    }
    private var routesContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button {
                if model.recording { model.stopTrack() } else { model.startTrack() }
            } label: {
                Label(model.recording ? "Завершить маршрут" : "Новый маршрут", systemImage: model.recording ? "stop.fill" : "plus")
                    .frame(maxWidth: .infinity).frame(height: 50)
            }.buttonStyle(.borderedProminent).tint(FBTheme.green)
            if model.recording {
                HStack {
                    Label(model.paused ? "На паузе" : "Идёт запись", systemImage: "record.circle")
                        .foregroundStyle(FBTheme.green)
                    Spacer()
                    Button(model.paused ? "Продолжить" : "Пауза") { model.togglePause() }
                }.fbCard()
            }
            if model.tracks.isEmpty && model.currentTrack == nil {
                emptyCard("Маршрутов пока нет", hint: "Начни запись на карте", icon: "figure.hiking")
            }
            ForEach(model.tracks) { track in
                HStack(spacing: 13) {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.title2).foregroundStyle(FBTheme.green)
                        .frame(width: 45, height: 45)
                        .background(FBTheme.green.opacity(0.13), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.name).font(.subheadline.bold())
                        Text("\(track.fixes.count) точек · \(Int(track.distanceMeters)) м")
                            .font(.caption).foregroundStyle(FBTheme.textSecondary)
                    }
                    Spacer()
                    if let url = model.exportGPX(track) {
                        ShareLink(item: url) { Image(systemName: "square.and.arrow.up").foregroundStyle(FBTheme.green) }
                    }
                }.fbCard()
            }
        }
    }
    private var markersContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            Button { model.addMarker() } label: {
                Label("Добавить метку по GPS", systemImage: "plus")
                    .frame(maxWidth: .infinity).frame(height: 50)
            }.buttonStyle(.borderedProminent).tint(FBTheme.green)
            if model.markers.isEmpty { emptyCard("Меток пока нет", hint: "Сначала включи GPS, затем сохрани точку", icon: "mappin.slash") }
            ForEach(model.markers) { marker in
                HStack(spacing: 12) {
                    Image(systemName: marker.symbol ?? "mappin.circle.fill")
                        .foregroundStyle(FBTheme.green).font(.title2)
                        .frame(width: 44, height: 44)
                        .background(FBTheme.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(marker.title).font(.subheadline.bold())
                        Text(String(format: "%.5f, %.5f", marker.coordinate.latitude, marker.coordinate.longitude))
                            .font(.caption).foregroundStyle(FBTheme.textSecondary)
                    }
                    Spacer(minLength: 6)
                    ShareLink(item: "geo:\(marker.coordinate.latitude),\(marker.coordinate.longitude)") {
                        Image(systemName: "square.and.arrow.up").foregroundStyle(FBTheme.green)
                    }
                }.fbCard()
            }
        }
    }

    // MARK: - Weather, wildlife and advanced screens
    private var serviceScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            pageTitle("Сервисы", subtitle: "Прогноз и животные Казахстана")
            Picker("Раздел", selection: $serviceSection) {
                ForEach(ServiceSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            if serviceSection == .weather {
                weatherContent
            } else {
                wildlifeContent
            }
        }
    }
    private var weatherContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                Label("ПОГОДА В ТЕКУЩЕЙ ТОЧКЕ", systemImage: "location.fill")
                    .font(.caption.bold()).foregroundStyle(FBTheme.green)
                HStack {
                    Text(weather.forecast?.temperatureC.map { "\(Int($0.rounded()))°" } ?? "—°")
                        .font(.system(size: 62, weight: .light, design: .rounded))
                    Spacer()
                    Image(systemName: "cloud.sun.fill")
                        .font(.system(size: 52)).foregroundStyle(FBTheme.green)
                }
                Text(weather.forecast == nil ? "Данные ещё не загружены" : "Источник: Open-Meteo")
                    .font(.subheadline).foregroundStyle(FBTheme.textSecondary)
                if weather.isCached { Text("Сохранённый прогноз").font(.caption).foregroundStyle(FBTheme.warning) }
            }.fbCard()
            HStack(spacing: 10) {
                weatherQuick("Ветер", icon: "wind")
                weatherQuick("Давление", icon: "barometer")
                weatherQuick("Осадки", icon: "cloud.rain.fill")
            }
            Button { showWeather = true } label: {
                FBActionPill(title: "Подробный прогноз", subtitle: "Почасовые данные и единицы измерения", icon: "calendar", tint: FBTheme.green)
            }.buttonStyle(.plain)
            Button { tab = .map; showWeatherLayers = true } label: {
                FBActionPill(title: "Погодная карта", subtitle: "Ветер · Давление · Осадки", icon: "square.3.layers.3d", tint: FBTheme.mint)
            }.buttonStyle(.plain)
            if model.coordinate == nil {
                Text("Для погоды нужна GPS-позиция").font(.caption).foregroundStyle(FBTheme.textSecondary)
            } else {
                Button("Обновить прогноз") {
                    if let coord = model.coordinate {
                        weather.refresh(latitude: coord.latitude, longitude: coord.longitude, strictOffline: !online)
                    }
                }.tint(FBTheme.green)
            }
            Text(weather.message).font(.caption).foregroundStyle(FBTheme.textSecondary)
        }
        .onAppear {
            if weather.forecast == nil, let coord = model.coordinate {
                weather.refresh(latitude: coord.latitude, longitude: coord.longitude, strictOffline: !online)
            }
        }
    }
    private func weatherQuick(_ title: String, icon: String) -> some View {
        Button { showWeather = true } label: {
            VStack(spacing: 9) {
                Image(systemName: icon).foregroundStyle(FBTheme.green).font(.title2)
                Text(title).font(.caption.bold()).foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity).frame(height: 72)
            .fbSoftCard()
        }.buttonStyle(.plain)
    }
    private var wildlifeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Наблюдения не означают разрешение на охоту.")
                .font(.footnote).foregroundStyle(FBTheme.textSecondary)
                .fbCard()
            Button {
                Task {
                    showGBIF = true
                    do { taxa = try await GBIFDiscovery.fetchKazakhstan(); wildlifeError = nil }
                    catch { wildlifeError = error.localizedDescription }
                    showGBIF = false
                }
            } label: {
                Label(showGBIF ? "Загрузка…" : "Загрузить наблюдения GBIF", systemImage: "arrow.down.circle")
                    .frame(maxWidth: .infinity).frame(height: 50)
            }
            .buttonStyle(.borderedProminent).tint(FBTheme.green).disabled(showGBIF)
            if let wildlifeError { Text(wildlifeError).foregroundStyle(FBTheme.danger).font(.caption) }
            ForEach(taxa) { item in
                HStack {
                    Image(systemName: "pawprint.fill").foregroundStyle(FBTheme.green)
                    Text(item.name).font(.subheadline)
                    Spacer()
                }.fbCard()
            }
            if taxa.isEmpty && !showGBIF {
                emptyCard("Каталог наблюдений не загружен", hint: "Выполни загрузку из GBIF или импортируй локальный JSON", icon: "pawprint")
            }
        }
    }
    private var moreScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            pageTitle("Ещё", subtitle: "Карты, настройки и поддержка")
            moreButton("Загрузки карт", hint: "MBTiles · GeoJSON · Каталоги", icon: "arrow.down.circle.fill") { showAdvanced = true }
            moreButton("Выбор картографической подложки", hint: "MapTiler · OpenFreeMap · Офлайн", icon: "square.3.layers.3d") { showLayers = true }
            moreButton("Диагностика", hint: "Встряхивание · Экспорт отчёта", icon: "waveform.path.ecg") { showDiagnostics = true }
            moreButton("О приложении", hint: "Автор · Версия · Источники", icon: "info.circle") { showAbout = true }
            moreButton("Дополнительные инструменты", hint: "Импорт, управление каталогами и параметры", icon: "gearshape.2") { showAdvanced = true }
            VStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 50)).foregroundStyle(FBTheme.green)
                Text("HUNT MAP KZ").font(.title2.bold())
                Text("Навигация · Казахстан").font(.caption).foregroundStyle(FBTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
        }
    }
    private func moreButton(_ title: String, hint: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.title3).foregroundStyle(FBTheme.green)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                    Text(hint).font(.caption2).foregroundStyle(FBTheme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(FBTheme.textSecondary)
            }.fbCard()
        }.buttonStyle(.plain)
    }
    private func emptyCard(_ title: String, hint: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38)).foregroundStyle(FBTheme.green)
            Text(title).font(.headline)
            Text(hint).font(.footnote).foregroundStyle(FBTheme.textSecondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28).fbCard()
    }
    private func pageTitle(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(subtitle).font(.subheadline).foregroundStyle(FBTheme.textSecondary)
        }
    }
}
