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
    assert 'HostingOfflineSheet' in ui
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
    assert 'PMTiles' in code and 'SHA256' in code
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
    ui = (IOS / "OfflineGridDownloadSheet.swift").read_text()
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
