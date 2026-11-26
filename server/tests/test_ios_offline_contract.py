"""Source-level guardrails, not a replacement for an iOS network trace / Xcode build."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / 'iOS' / 'HuntMap'


def test_offline_maplibre_has_no_online_tile_fallback():
    map_view = (IOS / 'OfflineMapView.swift').read_text()
    assert 'import MapLibre' in map_view
    assert 'import MapKit' not in map_view
    assert '"sources":{}' in map_view
    assert 'LocalMBTilesServer.shared' in map_view
    assert 'tileURLTemplates' in map_view
    assert 'URL(string: "mbtiles://' not in map_view
    # Remote style is allowed only behind an explicit user-controlled online flag.
    assert 'protomapsOfflineStyleURL ?? OfflineMapStyle.url' in map_view
    assert 'nativeOfflineStyleURL ?? OfflineMapStyle.url' not in map_view
    assert 'protomapsOnlineStyleURL' in map_view
    assert 'MapBasemap.protomaps.rawValue' in map_view
    assert 'MLNTilePyramidOfflineRegion' in (IOS / 'NativeOfflinePackStore.swift').read_text()
    assert 'HuntOfflineStyleURL' in (IOS / 'NativeOfflinePackStore.swift').read_text()
    sources = (IOS / 'MapSources.swift').read_text()
    assert 'https://tiles.openfreemap.org/styles/' in sources
    assert 'api.maptiler.com/maps/' in sources
    assert 'OfflineMapStyle.url' in map_view
    assert 'didFinishLoading style' in map_view


def test_maplibre_package_declared_and_local_import_available():
    project = (ROOT / 'iOS' / 'project.yml').read_text()
    tiles = (IOS / 'OfflineTiles.swift').read_text()
    ui = (IOS / 'MainView.swift').read_text()
    assert 'maplibre-gl-native-distribution' in project
    assert '- package: MapLibre' in project
    assert 'func importLocal(' in tiles
    assert 'RasterMBTiles.isSupported(temp)' in tiles
    assert 'Self.sha256(file: temp)' in tiles
    # Legacy screens have been removed, not merely hidden.
    assert not (IOS / 'LegacyMainView.swift').exists()
    assert 'LegacyMainView' not in ui
    assert 'startupSync.begin(' in ui
    assert 'StartupSyncScreen(' in ui
    assert 'HostingOfflineSheet' not in ui  # manual download screen is intentionally unreachable
    assert 'MapKit' not in tiles


def test_downloaded_roads_are_visible_offline_and_local_tiles_allowed():
    source = (IOS / 'OfflineMapView.swift').read_text()
    main = (IOS / 'MainView.swift').read_text()
    road = (IOS / 'OfflineRoadOverlayStore.swift').read_text()
    hosting = (IOS / 'HostingOfflineDownloads.swift').read_text()
    project = (ROOT / 'iOS/project.yml').read_text()
    assert 'NSAllowsLocalNetworking: true' in project
    assert 'OFFLINE|ROAD' in source
    assert 'offlineRoadLines: online ? [] : offlineRoads.lines' in main
    assert 'installedRoadFiles(in bounds:' in hosting
    assert 'Data(contentsOf: file)' in road
    assert 'Task.detached(priority: .utility)' in road
    assert 'onViewportChanged:' in main


def test_protomaps_native_pmtiles_integration():
    code = (IOS / 'ProtomapsOfflineStore.swift').read_text()
    style = (IOS / 'ProtomapsVectorStyle.swift').read_text()
    view = (IOS / 'OfflineMapView.swift').read_text()
    ui = (IOS / 'MainView.swift').read_text()
    assert 'pmtiles://' in style and 'absoluteString' in style
    assert 'roads' in style and 'path' in style and 'water' in style
    worker = (IOS / 'HuntBackgroundWork.swift').read_text()
    assert 'PMTiles' in code
    assert 'try await HuntBackgroundWork.digest(temp, pmtiles: true)' in code
    assert 'var hash = SHA256()' in worker
    assert 'hash.update(data: bytes)' in worker
    assert 'magic[7] == 3' in worker
    assert 'guard digest == item.sha256.lowercased()' in code
    assert code.index('guard digest == item.sha256.lowercased()') < code.index('replaceItemAt(destination')
    assert 'protomapsOfflineStyleURL' in view
    assert 'ProtomapsOfflineStore()' in ui


def test_protomaps_local_glyphs_and_sprites_are_downloaded():
    source = (IOS / 'ProtomapsAssets.swift').read_text()
    style = (IOS / 'ProtomapsVectorStyle.swift').read_text()
    assert 'Noto Sans Regular' in source
    assert '1024-1279' in source and '1280-1535' in source
    assert 'sprites/v4' in source
    assert 'ProtomapsAssets.ready(in: folder)' in style
    assert 'place_names_' in style


def test_protomaps_catalog_is_editable_and_diagnosed():
    store = (IOS / "ProtomapsOfflineStore.swift").read_text()
    ui = (IOS / "OfflineManagerScreen.swift").read_text()
    assert "catalogCandidates(" in store
    assert "setCatalogAddress(" in store
    assert "loadedCatalogURL" in store
    assert "rejectedPacks" in store
    assert "HTTP \\(statusCode)" in store
    assert "URL(string: raw, relativeTo: catalog)" in store
    assert "protomaps_catalog_address" in ui
    assert "Проверить хостинг и каталог" in ui


def test_offline_hybrid_is_file_backed():
    style = (IOS / "ProtomapsVectorStyle.swift").read_text()
    mapview = (IOS / "OfflineMapView.swift").read_text()
    store = (IOS / "ProtomapsOfflineStore.swift").read_text()
    assert "hybrid: Bool = false" in style
    assert "if !hybrid {" in style
    assert "protomaps-offline-hybrid.json" in style
    assert "hybridOfflineStyleURL" in store
    assert "protomapsHybridStyleURL" in mapview
    assert "style.insertLayer(raster, below: vector)" in mapview


def test_offline_style_cannot_fallback_to_remote_native_pack():
    mapview = (IOS / "OfflineMapView.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    assert "nativeOfflineStyleURL ?? OfflineMapStyle.url" not in mapview
    assert "Гибрид · полностью офлайн" in ui
    assert ".disabled(protomaps.installed.isEmpty || maps.installed.isEmpty)" in ui


def test_recorded_track_replay_and_bidirectional_follow():
    main = (IOS / "MainView.swift").read_text()
    follow = (IOS / "RecordedTrackFollow.swift").read_text()
    view = (IOS / "OfflineMapView.swift").read_text()
    assert "Воспроизвести: от начала" in main and "Воспроизвести: от конца" in main
    assert "Пройти от начала" in main and "Пройти от конца" in main
    assert "recorded_track_timeline" in main
    assert "recordedRouteRemaining" in main and "recordedRouteDeviation" in main
    assert "Array(original.reversed())" in follow
    assert "REPLAY|LOCATION" in view


def test_valhalla_local_cpp_route_engine_integration():
    project = (ROOT / "iOS/project.yml").read_text()
    engine = (IOS / "ValhallaLocalEngine.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    assert "valhalla-mobile" in project.lower()
    assert "import Valhalla" in engine
    assert "ValhallaConfig(tileExtractTar: archive)" in engine
    assert "route(rawRequest: payload)" in engine
    assert '"pedestrian" : "auto"' in engine
    assert "ValhallaPolyline6.decode" in engine
    assert "calculateLegacyRoute" in ui
    assert "planRoute(to:" in ui
    assert "route_start_guidance" in ui


def test_valhalla_download_and_windows_builder_contract():
    engine = (IOS / "ValhallaLocalEngine.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    builder = (ROOT / "tools/PREPARE_VALHALLA_WINDOWS.bat").read_text()
    assert "hunt-valhalla-v1" in engine
    assert "SHA256()" in engine
    startup = (IOS / "StartupSync.swift").read_text()
    assert "downloadFromHosting()" in startup  # automatic startup update, not a download button
    assert "ghcr.io/valhalla/valhalla-scripted:latest" in builder
    assert "serve_tiles=False" in builder
    assert "valhalla_tiles.tar" in builder


def test_recorded_route_guidance_handles_foreground_and_background_gps():
    model = (IOS / "FieldModel.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    assert "startRecordedRouteGuidance" in model
    assert "stopRecordedRouteGuidance" in model
    assert "manager.authorizationStatus == .authorizedAlways" in model
    assert "model.startRecordedRouteGuidance()" in ui
    assert "model.stopRecordedRouteGuidance()" in ui


def test_valhalla_turn_by_turn_russian_directions():
    engine = (IOS / "ValhallaLocalEngine.swift").read_text()
    main = (IOS / "MainView.swift").read_text()
    assert '"language": "ru-RU"' in engine
    assert '"directions_type": "instructions"' in engine
    assert 'begin_shape_index' in engine
    assert 'ValhallaManeuver' in engine
    assert 'refreshNextTurn(at:' in main
    assert 'Следующий манёвр' in main


def test_user_can_plan_and_follow_without_manual_download_buttons():
    ui = (IOS / "MainView.swift").read_text()
    startup = (IOS / "StartupSync.swift").read_text()
    assert 'Button("Построить маршрут")' in ui
    assert 'Label(plannedOrigin == nil ? "В путь" : "Маршрут от GPS"' in ui
    assert '.accessibilityIdentifier("route_start_guidance")' in ui
    assert "if plannedOrigin != nil" in ui
    assert "routeGuidance = true" in ui
    assert 'Label("Авто"' in ui and 'Label("Пешком"' in ui
    assert 'Скачать Valhalla' not in ui
    assert 'Загрузить карты' not in ui
    assert 'Скачать карту по сетке' not in ui
    assert 'startupSync.begin(' in ui and 'await protomaps.downloadAllAvailable()' in startup


def test_wind_prefetches_on_launch_and_progressively_refines():
    ui = (IOS / "MainView.swift").read_text()
    wind = (IOS / "WeatherGridService.swift").read_text()
    assert 'weatherGrid.load(hourOffset: 0)' in ui
    assert '.task(id: startupSync.presented)' in ui
    assert 'guard !startupSync.presented, !didPrefetchWeather' in ui
    assert 'if tab == .map && !startupSync.presented { mapScreen }' in ui
    assert 'coarse.width = 3' in wind and 'coarse.height = 3' in wind
    assert 'self.fetchGrid(region: coarse' in wind
    assert 'self.fetchGrid(region: detailed' in wind


def test_weather_grid_hourly_query_has_no_conflicting_forecast_days():
    source = (IOS / "WeatherGridService.swift").read_text()
    assert 'URLQueryItem(name: "start_hour", value: targetHour)' in source
    assert 'URLQueryItem(name: "end_hour", value: targetHour)' in source
    # Open-Meteo rejects forecast_days together with an explicit hour window (HTTP 400).
    assert 'fallback.queryItems?.removeAll' in source
    assert '$0.name == "start_hour" || $0.name == "end_hour"' in source
    assert 'fallback.queryItems?.append(URLQueryItem(name: "forecast_days", value: "8"))' in source
    assert 'http.statusCode != 200' in source


def test_weather_uses_lightweight_overlay_without_maplibre_shape_flood():
    map_view = (IOS / "OfflineMapView.swift").read_text()
    overlay = (IOS / "WeatherFieldOverlay.swift").read_text()
    wind = (IOS / "WindParticlesOverlay.swift").read_text()
    assert 'WeatherFieldOverlay(mapView: view, hostView: container)' in map_view
    assert 'WindParticlesOverlay(mapView: view, hostView: container)' in map_view
    assert 'container.addSubview(view)' in map_view
    assert 'hostView.addSubview(self)' in overlay and 'hostView.addSubview(self)' in wind
    assert 'mapView.addSubview(self)' not in overlay and 'mapView.addSubview(self)' not in wind
    assert 'fieldOverlay?.configure(grid: weatherGrid, layer: weatherLayer)' in map_view
    assert 'WeatherGeometry.shade(' not in map_view
    assert 'WeatherGeometry.windArrow(' not in map_view
    assert 'for subY in 0..<2' in overlay
    assert 'private let particleCount = 85' in wind
    assert 'link.preferredFramesPerSecond = 15' in wind


def test_weather_probability_contract():
    grid = (IOS / "WeatherGridService.swift").read_text()
    overlay = (IOS / "WeatherFieldOverlay.swift").read_text()
    sheet = (IOS / "WeatherMapSheet.swift").read_text()
    assert 'pressure_msl,precipitation,precipitation_probability' in grid
    assert 'let precipitation_probability: [Double?]?' in grid
    assert '(0...100).contains(p.precipitationProbability!)' in grid
    assert 'case .probability: return point.precipitationProbability' in overlay
    assert 'case .probability: return "%"' in sheet
    assert 'Для выбранного слоя нет данных.' in sheet
    assert 'Осадки не прогнозируются: карта прозрачная.' in sheet


def test_ground_labels_offline_and_camera_contract():
    labels = (IOS / "GroundLabelsOverlay.swift").read_text()
    map_view = (IOS / "OfflineMapView.swift").read_text()
    assert 'isUserInteractionEnabled = false' in labels
    assert 'hostView.addSubview(self)' in labels
    assert 'polygon.contains(center)' in labels
    assert 'zoom >= 6.5' in labels
    assert 'occupied.contains' in labels
    assert 'groundLabels?.configure(zones: zones, selectedID: highlightedGroundID, key: key)' in map_view
    assert 'groundLabels?.cameraChanged(force: true)' in map_view
    assert 'GroundLabelsOverlay(mapView: view, hostView: container)' in map_view


def test_no_map_selection_grid_and_gps_follow():
    ui = (IOS / 'MainView.swift').read_text()
    native = (IOS / 'OfflineMapView.swift').read_text()
    manager = (IOS / 'OfflineManagerScreen.swift').read_text()
    assert 'gridMode' not in ui and 'renderGrid' not in native
    assert 'Сетка карты' not in manager
    assert 'routeGuidance || recordedRouteFollowing' in ui
    assert 'followGPS(view: view, enabled: followsGPS' in native


def test_single_primary_icon_and_brand():
    import json, struct
    assets = IOS / "Assets.xcassets"
    primary = assets / "AppIcon.appiconset"
    assert sorted(p.name for p in assets.glob("*.appiconset")) == ["AppIcon.appiconset"]
    assert not list(assets.glob("AppIcon*Preview.imageset"))
    config = json.loads((primary / "Contents.json").read_text())
    for entry in config["images"]:
        if "filename" in entry:
            raw = (primary / entry["filename"]).read_bytes()
            assert raw[:8] == b'\x89PNG\r\n\x1a\n'
            width, height = struct.unpack(">II", raw[16:24])
            assert width == height == 1024
    project = (IOS.parent / "project.yml").read_text()
    assert 'CFBundleDisplayName: "QAZ TRAIL"' in project
    assert "PRODUCT_BUNDLE_IDENTIFIER: kz.huntmap.field" in project
    assert "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES" not in project
    assert not (IOS / "AdaptiveIconManager.swift").exists()
    assert "AdaptiveIconSettings" not in (IOS / "MainView.swift").read_text()


def test_offline_manager_defers_catalog_render_and_storage_probe():
    source = (IOS / "OfflineManagerScreen.swift").read_text()
    assert "LazyVStack" in source
    assert "if showPackages" in source
    assert "Task.detached(priority: .utility)" in source
    assert "installedByID" in source
    assert "let hashes = Set(" in source
    assert "switch packageKind" in source


def test_heavy_offline_work_is_awaited():
    worker = (IOS / "HuntBackgroundWork.swift").read_text()
    hosting = (IOS / "HostingOfflineDownloads.swift").read_text()
    pmtiles = (IOS / "ProtomapsOfflineStore.swift").read_text()
    main = (IOS / "MainView.swift").read_text()
    assert "withTaskCancellationHandler" in worker
    assert "Task.detached(priority: .utility)" in worker
    assert "try await HuntBackgroundWork.append" in hosting
    assert "try await HuntBackgroundWork.digest" in pmtiles
    assert "try await hosting.graph" in main
    assert "try Task.checkCancellation()" in main
    assert "async throws -> OfflineRouteGraph" in hosting
    assert "try await HuntBackgroundWork.run { try graph.path" in main
    assert "routeRequestID == requestID, routeDestination == destination" in main
    assert "legacyRouteTask?.cancel()" in main


def test_map_annotation_groups_and_track_stats_are_incremental():
    native = (IOS / "OfflineMapView.swift").read_text()
    field = (IOS / "FieldModel.swift").read_text()
    assert "String(describing: track)" not in native
    assert "lastRoadRevision != offlineRoadRevision" in native
    assert "lastTrackFixes != fixes" in native
    assert "lastNavigationPath != navigationPath" in native
    assert "gps.coordinate = coordinate" in native
    assert "TrackRendering.simplified" in native
    assert "fix.segmentStart == true" in native
    assert "currentTrack?.appendFix(" in field
    assert "cachedStatistics = nil" in field


def test_startup_releases_ui_and_gps_preserves_active_sessions():
    startup = (IOS / "StartupSync.swift").read_text()
    field = (IOS / "FieldModel.swift").read_text()
    main = (IOS / "MainView.swift").read_text()
    app = (IOS / "HuntMapApp.swift").read_text()
    assert "var presented = false" in startup
    assert "presented = true" not in startup
    assert "Task.sleep(for: .seconds(3))" in startup
    assert "await model.loadAtStartup(seedGrounds: !recoveryMode)" in app
    assert "enter && state.startupLoaded" in app
    assert "if showMain, let state" in app
    assert "Безопасный режим" in app
    assert "hunt.launch.stage" in app
    assert "Task.detached(priority: .utility)" in field
    assert "hunt.startup.autoDownloadPackages" in startup
    assert startup.index("hunt.startup.autoDownloadPackages") < startup.index("await protomaps.downloadAllAvailable()")
    assert "(recording && !paused) || navigatingRecordedTrack || monitoredGroundID != nil" in field
    assert "foregroundGPS || background" in field
    assert "manager.stopUpdatingLocation()" in field
    assert "model.setForegroundGPS(phase == .active)" in main
    assert "onCancelStartup: { startupSync.skip() }" in main


def test_active_track_journal_is_committed_before_publish():
    field = (IOS / "FieldModel.swift").read_text()
    assert "try TrackPointJournal.append(point, index: track.fixes.count" in field
    assert field.index("try TrackPointJournal.append(point") < field.index("currentTrack?.appendFix(point)")
    assert "TrackPointJournal.recover(TrackFix.self" in field
    assert "try writeSnapshot(snapshot)" in field
    assert field.index("try writeSnapshot(snapshot)", field.index("func stopTrack()")) < field.index("try TrackPointJournal.remove")


def test_camera_freshness_and_power_aware_animation():
    native = (IOS / "OfflineMapView.swift").read_text()
    weather = (IOS / "AnimatedWeatherDashboard.swift").read_text()
    main = (IOS / "MainView.swift").read_text()
    assert "followValidUntil = fixTime.addingTimeInterval(30)" in native
    assert "restoreFollowCenterIfNeeded(mapView)" in native
    assert "followFixTime: model.fieldFixTime" in main
    assert "constrained ? 1.0 / 15.0 : 1.0 / 30.0" in weather
    assert "TrackExportCleanup.removeExpired" in main


def test_recorded_navigation_updates_from_gps_not_view():
    model = (IOS / "FieldModel.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    voice = (IOS / "NavigationVoice.swift").read_text()
    assert "updateRecordedGuidance(fix, position: p)" in model
    assert "tracker.update(position: position, accuracy: fix.horizontalAccuracy" in model
    assert "model.$recordedGuidanceResult" in ui
    assert "AVSpeechSynthesizer()" in voice
    assert "timestamp.timeIntervalSince($0) >= 120" in voice
    assert "UNUserNotificationCenter.current()" in voice
    assert "hunt.navigation.voice" in (IOS / "HuntSettingsScreen.swift").read_text()


def test_course_up_and_explicit_azimuth():
    native = (IOS / "OfflineMapView.swift").read_text()
    ui = (IOS / "MainView.swift").read_text()
    assert "view.setDirection(course, animated: animated)" in native
    assert "Date().timeIntervalSince(fixTime) < 30" in native
    assert "(model.fieldSpeed ?? 0) >= 3.6" in ui
    assert 'ForEach(["Автомобиль", "Лагерь"]' in ui
    assert 'АЗИМУТ · НЕ ДОРОЖНЫЙ МАРШРУТ' in ui
    assert "private func beginAzimuth" in ui
    assert "navigationPath = []" in ui[ui.index("private func beginAzimuth"):ui.index("private var navigationPanel")]


def test_track_editor_creates_copies_atomically():
    editor = (IOS / "TrackEditScreen.swift").read_text()
    field = (IOS / "FieldModel.swift").read_text()
    assert "TrackEdit.trim" in editor and "TrackEdit.split" in editor and "TrackEdit.join" in editor
    assert "copy.segmentStart = true" in editor
    assert "try model.saveEditedTracks(copies)" in editor
    save = field[field.index("func saveEditedTracks"):field.index("func deleteTrack")]
    assert save.index("try writeSnapshot(snapshot)") < save.index("tracks = snapshot.tracks")
    assert "Редактировать копию" in (IOS / "MainView.swift").read_text()


def test_address_route_planner_uses_selected_origin():
    main = (IOS / "MainView.swift").read_text()
    assert "guard let current = origin ?? model.coordinate" in main
    assert "origin: addressOrigin?.point" in main
    assert "origin: plannedOrigin" in main
    assert "refreshNextTurn(at: plannedOrigin ?? model.coordinate ?? current)" in main
    assert "Маршрут от GPS" in main
