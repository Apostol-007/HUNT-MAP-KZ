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
    @AppStorage("hunt.map.style") private var mapStyle = (MapTilerConfiguration.isConfigured ? MapBasemap.satellite.rawValue : MapBasemap.outdoors.rawValue)
    private var hasMapTilerKey: Bool { MapTilerConfiguration.isConfigured }

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
    @State private var showSearch = false
    @State private var searchText = ""
    @State private var selectedRouteFilter = "Все"
    @State private var selectedMarkerFilter = "Все"
    @State private var selectedWildlifeMode = "По угодьям"
    @State private var centerRequest = 0
    @State private var zoomCommand = 0
    @AppStorage("hunt.showGrounds") private var showGrounds = true
    @AppStorage("hunt.showMarkers") private var showMarkersOnMap = true
    @AppStorage("hunt.showGPS") private var showGPSOnMap = true
    @AppStorage("hunt.showTrack") private var showTrackOnMap = true
    @State private var showAnimalsLayer = false
    @State private var editingMarker: Marker?
    @State private var selectedMapMarker: MapMarkerSelection?
    @State private var pendingMapPoint: GeoPoint?
    @State private var pendingMapZone: GeoZone?
    @State private var movingMarkerID: UUID?
    @State private var showMapPointActions = false
    @State private var markerToDelete: Marker?
    @State private var trackToDelete: Track?
    @State private var mapFocus: GeoPoint?
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
        .background(HuntReference.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .background(ShakeDetector().frame(width: 1, height: 1))
        .onReceive(NotificationCenter.default.publisher(for: .huntShake)) { _ in showDiagnostics = true }
        .sheet(isPresented: $showLayers) { layerSheet }
        .sheet(isPresented: $showSearch) { mapSearchSheet }
        .sheet(item: $selectedMapMarker) { selection in
            MapMarkerDetails(markerID: selection.id, model: model,
                onShowOnMap: { point in
                    mapFocus = point
                    centerRequest += 1
                    tab = .map
                    selectedMapMarker = nil
                },
                onMove: {
                    movingMarkerID = selection.id
                    selectedMapMarker = nil
                })
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Точка на карте", isPresented: $showMapPointActions, titleVisibility: .visible) {
            Button("Поставить метку") {
                if let point = pendingMapPoint, let marker = model.addMarker(at: point) {
                    showMarkersOnMap = true
                    selectedMapMarker = MapMarkerSelection(id: marker.id)
                }
                pendingMapPoint = nil
                pendingMapZone = nil
            }
            if pendingMapZone != nil {
                Button("Информация об угодье") {
                    zone = pendingMapZone
                    pendingMapPoint = nil
                    pendingMapZone = nil
                }
            }
            Button("Отмена", role: .cancel) { pendingMapPoint = nil; pendingMapZone = nil }
        } message: {
            if let point = pendingMapPoint {
                Text(String(format: "Широта %.6f, долгота %.6f", point.latitude, point.longitude))
            }
        }
        .sheet(item: $editingMarker) { marker in
            MarkerEditor(marker: marker,
                         onSave: { model.saveMarker($0) },
                         onDelete: { model.deleteMarker(id: $0) })
        }
        .confirmationDialog("Удалить метку?", isPresented: Binding(
            get: { markerToDelete != nil },
            set: { if !$0 { markerToDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let markerToDelete { model.deleteMarker(id: markerToDelete.id) }
                markerToDelete = nil
            }
            Button("Отмена", role: .cancel) { markerToDelete = nil }
        }
        .confirmationDialog("Удалить маршрут?", isPresented: Binding(
            get: { trackToDelete != nil },
            set: { if !$0 { trackToDelete = nil } })) {
            Button("Удалить", role: .destructive) {
                if let trackToDelete { model.deleteTrack(id: trackToDelete.id) }
                trackToDelete = nil
            }
            Button("Отмена", role: .cancel) { trackToDelete = nil }
        }
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
            .padding(.top, 14)
            .padding(.bottom, 112)
        }
        .scrollIndicators(.hidden)
        .background(HuntReference.background.ignoresSafeArea())
    }

    private var navigation: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { item in
                Button { withAnimation(.easeOut(duration: 0.16)) { tab = item } } label: {
                    FBTabButton(title: item.rawValue, systemImage: item.icon, active: tab == item)
                        .frame(height: 57)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab_\(item.rawValue)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.top, 8)
        .padding(.bottom, 5)
        .background(HuntReference.background.opacity(0.98))
        .overlay(alignment: .top) { Rectangle().fill(HuntReference.separator).frame(height: 1) }
        .padding(.bottom, 0)
    }

    // MARK: - Screen 1: Home, screenshot hierarchy
    private var homeScreen: some View {
        VStack(alignment: .leading, spacing: 19) {
            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 31, weight: .bold))
                    .foregroundStyle(HuntReference.green)
                VStack(alignment: .leading, spacing: 3) {
                    Text("HUNT MAP KZ").font(.system(size: 19, weight: .bold))
                    Text("Охота · Карты · Навигация")
                        .font(.system(size: 11))
                        .foregroundStyle(HuntReference.muted)
                }
                Spacer()
                Button { showDiagnostics = true } label: {
                    Image(systemName: "bell.badge")
                        .foregroundStyle(HuntReference.green)
                        .frame(width: 42, height: 42)
                        .background(HuntReference.card, in: Circle())
                }
                .accessibilityLabel("Диагностика и события")
            }
            Button { tab = .map } label: {
                ZStack(alignment: .bottomLeading) {
                    LinearGradient(colors: [Color(red: 0.08, green: 0.32, blue: 0.25),
                                            HuntReference.card, Color(red: 0.04, green: 0.09, blue: 0.08)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "mountain.2.fill")
                        .font(.system(size: 150, weight: .ultraLight))
                        .foregroundStyle(HuntReference.mint.opacity(0.28))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .offset(x: 15, y: 12)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Карты\nохотугодий\nКазахстана")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                        Text("Офлайн · GPS · Границы")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    .padding(20)
                }
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Быстрые действия").font(.headline.bold())
            LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 10) {
                ReferenceActionCard(title: "Карта и угодья", subtitle: "Открыть карту", symbol: "map") { tab = .map }
                ReferenceActionCard(title: "Загрузить карты", subtitle: "Офлайн-районы", symbol: "arrow.down.circle") { showAdvanced = true }
                ReferenceActionCard(title: "Мои маршруты", subtitle: "Треки и GPX", symbol: "mappin.and.ellipse") { dataSection = .routes; tab = .data }
                ReferenceActionCard(title: "Слои и погода", subtitle: "Прогноз и карта", symbol: "square.3.layers.3d") { tab = .map; showLayers = true }
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("Мои данные").font(.headline.bold())
                HStack {
                    stat("Маршруты", model.tracks.count)
                    Spacer()
                    stat("Метки", model.markers.count)
                    Spacer()
                    stat("Угодья", model.zones.count)
                }
            }
            .padding(17)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(HuntReference.muted)
            Text(String(value)).font(.system(size: 23, weight: .bold)).foregroundStyle(.white)
        }
    }

    // MARK: - Screen 2: Map. Map canvas itself must fill UIWindow bounds.
    private var mapScreen: some View {
        ZStack {
            OfflineMapView(zones: showGrounds ? model.zones : [],
                           position: showGPSOnMap ? model.coordinate : nil,
                           markers: showMarkersOnMap ? model.markers : [],
                           track: showTrackOnMap ? model.currentTrack : nil,
                           tileFiles: maps.paths, tileRevision: maps.revision,
                           online: online, selectedZone: $zone,
                           weatherGrid: weatherLayer == .none ? nil : weatherGrid.grid,
                           weatherLayer: weatherLayer,
                           centerRequest: centerRequest,
                           zoomCommand: zoomCommand,
                           focusCoordinate: mapFocus,
                           onMapTap: { point in
                               if let id = movingMarkerID {
                                   if var marker = model.markers.first(where: { $0.id == id }) {
                                       marker.coordinate = point
                                       model.saveMarker(marker)
                                       selectedMapMarker = MapMarkerSelection(id: id)
                                   }
                                   movingMarkerID = nil
                               } else {
                                   pendingMapPoint = point
                                   pendingMapZone = model.zones.first(where: { $0.contains(point) })
                                   showMapPointActions = true
                               }
                           },
                           onMarkerTap: { id in
                               if movingMarkerID == nil {
                                   selectedMapMarker = MapMarkerSelection(id: id)
                               }
                           })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.container, edges: .all)
            LinearGradient(colors: [.black.opacity(0.48), .clear, .black.opacity(0.28)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Button { showSearch = true } label: {
                        HStack(spacing: 9) {
                            Image(systemName: "magnifyingglass")
                            Text("Поиск мест, охотугодий, точек")
                                .lineLimit(1).minimumScaleFactor(0.72)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 13)
                        .frame(height: 43)
                        .background(HuntReference.card.opacity(0.97), in: Capsule())
                    }
                    Button { showLayers = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 19, weight: .semibold))
                            .foregroundStyle(HuntReference.green)
                            .frame(width: 43, height: 43)
                            .background(HuntReference.card.opacity(0.97), in: Circle())
                    }
                    .accessibilityLabel("Слои")
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                HStack {
                    Spacer()
                    VStack(spacing: 9) {
                        circleMapButton("square.3.layers.3d", label: "Слои") { showLayers = true }
                        circleMapButton("cloud.sun.fill", label: "Погода") { showWeatherLayers = true }
                        circleMapButton("location.fill", label: "Моё местоположение") {
                            mapFocus = nil
                            model.requestGPS()
                            centerRequest += 1
                        }
                        Spacer().frame(height: 8)
                        circleMapButton("plus", label: "Приблизить") { zoomCommand += 1 }
                        circleMapButton("minus", label: "Отдалить") { zoomCommand -= 1 }
                    }
                }
                .padding(.top, 16)
                .padding(.horizontal, 13)
                Spacer(minLength: 0)
                if let movingMarkerID {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.point.up.left.fill")
                        Text("Нажмите на новое место метки")
                        Spacer()
                        Button("Отмена") { self.movingMarkerID = nil }
                    }
                    .font(.caption.bold())
                    .padding(12)
                    .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier("marker_move_mode")
                }
                if weatherLayer != .none {
                    Button { showWeatherLayers = true } label: {
                        Label("\(weatherLayer.rawValue) · \(weatherGrid.forecastLabel)", systemImage: "cloud.fill")
                            .font(.caption.bold())
                            .foregroundStyle(HuntReference.green)
                            .padding(10)
                            .background(HuntReference.card.opacity(0.94), in: Capsule())
                    }
                    .padding(.bottom, 8)
                }
                if model.recording {
                    HStack(spacing: 8) {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        Text(model.paused ? "Маршрут на паузе" : "Идёт запись маршрута")
                        Spacer()
                        Button(model.paused ? "Продолжить" : "Пауза") { model.togglePause() }
                    }
                    .font(.caption.bold())
                    .padding(12)
                    .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 13)
                    .padding(.bottom, 8)
                }
                HStack(spacing: 10) {
                    miniMapAction("location.north.fill", title: "GPS") { mapFocus = nil; model.requestGPS(); centerRequest += 1 }
                    miniMapAction("mappin.circle.fill", title: "Метка") { model.addMarker() }
                    miniMapAction(model.recording ? "stop.fill" : "record.circle.fill",
                                  title: model.recording ? "Стоп" : "Запись") {
                        if model.recording { model.stopTrack() } else { model.startTrack() }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 84)
            }
        }
    }

    private func circleMapButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(HuntReference.green)
                .frame(width: 47, height: 47)
                .background(HuntReference.card.opacity(0.95), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    private func miniMapAction(_ symbol: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 47)
                .background(HuntReference.card.opacity(0.95), in: RoundedRectangle(cornerRadius: 17))
        }
        .buttonStyle(.plain)
    }

    private var mapSearchSheet: some View {
        NavigationStack {
            List {
                Section("Охотугодья · локальный каталог") {
                    ForEach(model.zones.filter { searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText) }) { ground in
                        Button {
                            showSearch = false
                            tab = .map
                            zone = ground
                        } label: {
                            Label(ground.name, systemImage: "map")
                        }
                    }
                }
                Section("Метки · сохранённые") {
                    ForEach(model.markers.filter { searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(searchText) }) { marker in
                        Button {
                            showSearch = false
                            tab = .map
                            mapFocus = marker.coordinate
                            centerRequest += 1
                        } label: {
                            HStack {
                                Label(marker.title, systemImage: "mappin.circle")
                                Spacer()
                                Text(String(format: "%.4f, %.4f", marker.coordinate.latitude, marker.coordinate.longitude))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Название охотугодья или метки")
            .navigationTitle("Поиск на карте")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { showSearch = false } } }
        }
    }

    // MARK: - Screen 3: Layers
    private var layerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    ReferencePageHeader(title: "Слои карты")
                        .padding(.bottom, 7)
                    ReferenceLayerRow(symbol: "map", title: "Охотугодья",
                                      detail: "Границы и информация", enabled: $showGrounds)
                    ReferenceLayerRow(symbol: "mountain.2", title: "Рельеф",
                                      detail: "3D-высоты: ожидается источник DEM", enabled: reliefBinding,
                                      available: false)
                    ReferenceLayerRow(symbol: "globe.europe.africa.fill", title: "Спутник",
                                      detail: hasMapTilerKey ? "Снимки высокой детализации" : "Нужен ключ MapTiler",
                                      enabled: satelliteBinding, available: hasMapTilerKey)
                    ReferenceLayerRow(symbol: "map.fill", title: "Топографическая",
                                      detail: "Outdoor: местность и тропы", enabled: topographicBinding)
                    ReferenceLayerRow(symbol: "cloud.sun", title: "Погода",
                                      detail: "Ветер, давление, осадки", enabled: weatherEnabledBinding)
                    ReferenceLayerRow(symbol: "pawprint.fill", title: "Животные",
                                      detail: "Нужны геоданные о видах", enabled: $showAnimalsLayer,
                                      available: false)
                    Text("Виды животных отображаются в справочнике; пространственный слой включим после получения проверенного покрытия и прав на публикацию.")
                        .font(.caption2).foregroundStyle(HuntReference.muted)
                    Toggle("Онлайн-подложка", isOn: $online)
                        .tint(HuntReference.green)
                        .padding(.vertical, 9)
                    ReferencePrimaryButton(title: "Закрыть", symbol: "checkmark") { showLayers = false }
                }
                .padding(17)
            }
            .background(HuntReference.background.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { showLayers = false } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var reliefBinding: Binding<Bool> {
        Binding(get: { mapStyle == MapBasemap.outdoors.rawValue },
                set: { mapStyle = $0 ? MapBasemap.outdoors.rawValue : MapBasemap.bright.rawValue; if $0 { online = true } })
    }
    private var satelliteBinding: Binding<Bool> {
        Binding(get: { mapStyle == MapBasemap.satellite.rawValue },
                set: { if $0 && hasMapTilerKey { mapStyle = MapBasemap.satellite.rawValue; online = true }
                       else if !$0 { mapStyle = MapBasemap.bright.rawValue } })
    }
    private var topographicBinding: Binding<Bool> {
        Binding(get: { mapStyle == MapBasemap.outdoors.rawValue },
                set: { mapStyle = $0 ? MapBasemap.outdoors.rawValue : MapBasemap.bright.rawValue; if $0 { online = true } })
    }
    private var weatherEnabledBinding: Binding<Bool> {
        Binding(get: { weatherLayer != .none },
                set: { if $0 { showLayers = false; showWeatherLayers = true }
                       else { weatherLayer = .none } })
    }

    // MARK: - Screens 5 & 6: Data / routes / markers
    private var dataScreen: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                ReferenceChip(title: "Маршруты", selected: dataSection == .routes) { dataSection = .routes }
                ReferenceChip(title: "Метки", selected: dataSection == .markers) { dataSection = .markers }
            }
            if dataSection == .routes { routesContent } else { markersContent }
        }
    }

    private var routesContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            ReferencePageHeader(title: "Маршруты")
            ReferencePrimaryButton(title: model.recording ? "Завершить маршрут" : "Новый маршрут",
                                   symbol: model.recording ? "stop.fill" : "plus") {
                if model.recording { model.stopTrack() } else { model.startTrack() }
            }
            HStack(spacing: 8) {
                ForEach(["Все", "Активные", "Архив"], id: \.self) { filter in
                    ReferenceChip(title: filter, selected: selectedRouteFilter == filter) {
                        selectedRouteFilter = filter
                    }
                }
            }
            if model.recording && selectedRouteFilter != "Архив" {
                HStack(spacing: 11) {
                    Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.currentTrack?.name ?? "Активная запись").font(.subheadline.bold())
                        Text(model.paused ? "На паузе" : "Идёт запись").font(.caption).foregroundStyle(HuntReference.muted)
                    }
                    Spacer()
                    Button(model.paused ? "Продолжить" : "Пауза") { model.togglePause() }
                        .font(.caption.bold()).foregroundStyle(HuntReference.green)
                }
                .fbCard()
            }
            if selectedRouteFilter != "Активные" {
                ForEach(model.tracks) { track in
                    routeRow(track)
                }
            }
            if (selectedRouteFilter == "Активные" && !model.recording) ||
               (selectedRouteFilter != "Активные" && model.tracks.isEmpty && !model.recording) {
                ReferenceEmptyCard(title: "Маршрутов пока нет",
                                   detail: "Начни запись GPS на карте", symbol: "figure.hiking")
            }
        }
    }

    private func routeDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return hours > 0 ? "\(hours) ч \(minutes) мин" : "\(minutes) мин"
    }

    private func routeRow(_ track: Track) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                .foregroundStyle(HuntReference.green)
                .font(.title2)
                .frame(width: 43, height: 43)
                .background(HuntReference.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 5) {
                Text(track.name).font(.subheadline.bold())
                Text(String(format: "%.2f км · %d точек · %@", track.distanceMeters / 1000,
                            track.fixes.count, routeDuration(track.durationSeconds)))
                    .font(.caption).foregroundStyle(HuntReference.muted)
                Text(track.createdAt.formatted(date: .numeric, time: .omitted))
                    .font(.caption2).foregroundStyle(HuntReference.muted)
            }
            Spacer(minLength: 2)
            Menu {
                if let file = model.exportGPX(track) {
                    ShareLink(item: file) { Label("Поделиться GPX", systemImage: "square.and.arrow.up") }
                }
                Button("Удалить маршрут", systemImage: "trash", role: .destructive) {
                    trackToDelete = track
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
        }
        .fbCard()
    }

    private var markersContent: some View {
        VStack(alignment: .leading, spacing: 15) {
            ReferencePageHeader(title: "Метки")
            ReferencePrimaryButton(title: "Добавить метку", symbol: "plus") {
                model.addMarker(kind: selectedMarkerFilter == "Все" ? "Точка" : selectedMarkerFilter)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["Все", "База", "Зверь", "Кормушка", "Другое"], id: \.self) { category in
                        ReferenceChip(title: category, selected: selectedMarkerFilter == category) {
                            selectedMarkerFilter = category
                        }
                    }
                }
            }
            ForEach(filteredMarkers) { marker in
                markerRow(marker)
            }
            if filteredMarkers.isEmpty {
                ReferenceEmptyCard(title: "Нет меток в этой категории",
                                   detail: "Добавь точку через GPS или выбери другую категорию",
                                   symbol: "mappin.slash")
            }
        }
    }

    private var filteredMarkers: [Marker] {
        model.markers.filter { selectedMarkerFilter == "Все" || markerCategory($0) == selectedMarkerFilter }
    }
    private func markerCategory(_ marker: Marker) -> String {
        let description = (marker.kind + " " + (marker.symbol ?? "")).lowercased()
        if description.contains("база") || description.contains("лагерь") || description.contains("дом") { return "База" }
        if description.contains("звер") || description.contains("живот") || description.contains("paw") || description.contains("лось") { return "Зверь" }
        if description.contains("корм") { return "Кормушка" }
        return "Другое"
    }
    private func markerRow(_ marker: Marker) -> some View {
        HStack(spacing: 12) {
            Image(systemName: marker.symbol ?? "mappin.circle.fill")
                .font(.title2)
                .foregroundStyle(HuntReference.green)
                .frame(width: 43, height: 43)
                .background(HuntReference.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
            VStack(alignment: .leading, spacing: 5) {
                Text(marker.title).font(.subheadline.bold())
                Text(String(format: "%.5f, %.5f", marker.coordinate.latitude, marker.coordinate.longitude))
                    .font(.caption).foregroundStyle(HuntReference.muted)
            }
            Spacer()
            Menu {
                Button("Показать на карте", systemImage: "map") {
                    tab = .map
                    mapFocus = marker.coordinate
                    centerRequest += 1
                }
                Button("Редактировать", systemImage: "pencil") { editingMarker = marker }
                ShareLink(item: "geo:\(marker.coordinate.latitude),\(marker.coordinate.longitude)") {
                    Label("Поделиться точкой", systemImage: "square.and.arrow.up")
                }
                Button("Удалить", systemImage: "trash", role: .destructive) { markerToDelete = marker }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.white)
                    .frame(width: 35, height: 35)
            }
        }
        .fbCard()
    }

    // MARK: - Screen 4: Weather, Screen 7: Animals, Screen 8: More
    private var serviceScreen: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 8) {
                ReferenceChip(title: "Погода", selected: serviceSection == .weather) { serviceSection = .weather }
                ReferenceChip(title: "Животные", selected: serviceSection == .wildlife) { serviceSection = .wildlife }
            }
            if serviceSection == .weather { weatherContent } else { wildlifeContent }
        }
    }

    private var weatherContent: some View {
        VStack(alignment: .leading, spacing: 13) {
            ReferencePageHeader(title: "Погода")
            Label("По текущей GPS-позиции", systemImage: "mappin.circle.fill")
                .font(.caption)
                .foregroundStyle(HuntReference.muted)
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "cloud.sun.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(HuntReference.mint)
                    Text(weather.forecast?.temperatureC.map { "\(Int($0.rounded()))°" } ?? "—°")
                        .font(.system(size: 46, weight: .light, design: .rounded))
                    Text(weather.forecast == nil ? "Нет прогноза" : "Прогноз Open-Meteo")
                        .font(.caption)
                        .foregroundStyle(HuntReference.muted)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 13) {
                    weatherMetric("Ветер", value: weather.forecast?.current.windSpeedKmh.map { String(format: "%.1f км/ч", $0) } ?? "—", icon: "wind")
                    weatherMetric("Давление", value: weather.forecast?.current.pressureMSLHpa.map { String(format: "%.0f гПа", $0) } ?? "—", icon: "barometer")
                    weatherMetric("Осадки", value: weather.forecast?.current.precipitationMm.map { String(format: "%.1f мм", $0) } ?? "—", icon: "cloud.rain")
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 22))

            if let forecast = weather.forecast, !forecast.hourly.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(Array(forecast.hourly.prefix(8).enumerated()), id: \.offset) { _, item in
                            VStack(spacing: 8) {
                                Text(item.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.caption2).foregroundStyle(HuntReference.muted)
                                Image(systemName: "clock")
                                    .foregroundStyle(HuntReference.green)
                                Text(item.precipitationProbabilityPercent.map { "\(Int($0))%" } ?? "—")
                                    .font(.caption.bold())
                            }
                        }
                    }
                    .padding(14)
                }
                .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 19))
            } else {
                Text("Почасовой прогноз появится после загрузки данных")
                    .font(.caption).foregroundStyle(HuntReference.muted)
                    .padding(15)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 19))
            }
            VStack(spacing: 0) {
                serviceAction("Прогноз по часам", icon: "calendar") { showWeather = true }
                Divider().overlay(HuntReference.separator)
                serviceAction("Карта ветра", icon: "wind") { weatherLayer = .wind; openWeatherMap() }
                Divider().overlay(HuntReference.separator)
                serviceAction("Карта осадков", icon: "drop") { weatherLayer = .precipitation; openWeatherMap() }
                Divider().overlay(HuntReference.separator)
                serviceAction("Карта давления", icon: "barometer") { weatherLayer = .pressure; openWeatherMap() }
            }
            .padding(.horizontal, 13)
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 21))
            if let point = model.coordinate {
                Button(weather.busy ? "Обновляется…" : "Обновить прогноз") {
                    weather.refresh(latitude: point.latitude, longitude: point.longitude, strictOffline: !online)
                }
                .font(.footnote.bold())
                .foregroundStyle(HuntReference.green)
                .disabled(weather.busy)
            } else {
                Text("Включи GPS, чтобы получить прогноз для своего местоположения")
                    .font(.caption).foregroundStyle(HuntReference.muted)
            }
            Text(weather.message).font(.caption2).foregroundStyle(HuntReference.muted)
        }
        .onAppear {
            if weather.forecast == nil, let point = model.coordinate {
                weather.refresh(latitude: point.latitude, longitude: point.longitude, strictOffline: !online)
            }
        }
    }
    private func weatherMetric(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(HuntReference.green).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(HuntReference.muted)
                Text(value).font(.caption.bold())
            }
        }
    }
    private func serviceAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon).foregroundStyle(HuntReference.green).frame(width: 27)
                Text(title).font(.subheadline.bold()).foregroundStyle(.white)
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(HuntReference.muted)
            }
            .frame(height: 54)
        }
        .buttonStyle(.plain)
    }
    private func openWeatherMap() {
        tab = .map
        showWeatherLayers = true
    }

    private var wildlifeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ReferencePageHeader(title: "Животные")
            HStack(spacing: 8) {
                ForEach(["По угодьям", "Справочник"], id: \.self) { name in
                    ReferenceChip(title: name, selected: selectedWildlifeMode == name) {
                        selectedWildlifeMode = name
                    }
                }
            }
            if selectedWildlifeMode == "По угодьям" {
                if animals.packs.isEmpty {
                    ReferenceEmptyCard(title: "Каталоги животных не загружены",
                                       detail: "Импортируй подтверждённые сведения об угодье",
                                       symbol: "pawprint")
                }
                ForEach(Array(animals.packs.enumerated()), id: \.offset) { _, pack in
                    VStack(alignment: .leading, spacing: 11) {
                        Text("Угодье: \(pack.ground_id)").font(.headline)
                        Text("Источник: \(pack.source)").font(.caption).foregroundStyle(HuntReference.muted)
                        ForEach(pack.taxa) { taxon in
                            HStack {
                                Image(systemName: "pawprint.fill").foregroundStyle(HuntReference.green)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(taxon.name_ru ?? taxon.name_kk ?? taxon.scientific_name).font(.subheadline.bold())
                                    Text("Статус: \(taxon.category) · записей: \(taxon.evidence_count)")
                                        .font(.caption2).foregroundStyle(HuntReference.muted)
                                }
                                Spacer()
                            }
                        }
                    }.fbCard()
                }
            } else {
                ReferenceEmptyCard(title: "Справочник наблюдений GBIF",
                                   detail: "Публичные наблюдения не подтверждают право на охоту",
                                   symbol: "book.closed")
                ReferencePrimaryButton(title: showGBIF ? "Загрузка…" : "Обновить справочник", symbol: "arrow.clockwise") {
                    Task {
                        showGBIF = true
                        do { taxa = try await GBIFDiscovery.fetchKazakhstan(); wildlifeError = nil }
                        catch { wildlifeError = error.localizedDescription }
                        showGBIF = false
                    }
                }
                .disabled(showGBIF)
                if let wildlifeError { Text(wildlifeError).foregroundStyle(.red).font(.caption) }
                ForEach(taxa) { animal in
                    HStack {
                        Image(systemName: "pawprint.fill").foregroundStyle(HuntReference.green)
                        Text(animal.name).font(.subheadline)
                        Spacer()
                    }.fbCard()
                }
            }
            Button("Импорт и обновления каталогов") { showAdvanced = true }
                .font(.footnote.bold()).foregroundStyle(HuntReference.green)
        }
    }

    private var moreScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            ReferencePageHeader(title: "Ещё")
            VStack(spacing: 0) {
                ReferenceMenuRow(symbol: "arrow.down.circle", title: "Загрузки карт") { showAdvanced = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "waveform.path.ecg", title: "Диагностика") { showDiagnostics = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "gearshape", title: "Настройки") { showLayers = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "arrow.triangle.2.circlepath", title: "Синхронизация") { showAdvanced = true }
                Divider().overlay(HuntReference.separator)
                ReferenceMenuRow(symbol: "info.circle", title: "О приложении") { showAbout = true }
            }
            .background(HuntReference.card, in: RoundedRectangle(cornerRadius: 20))
            VStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 50, weight: .bold))
                    .foregroundStyle(HuntReference.green)
                Text("HUNT MAP KZ").font(.headline.bold())
                Text("Версия \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "неизвестна")")
                    .font(.caption).foregroundStyle(HuntReference.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 42)
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
