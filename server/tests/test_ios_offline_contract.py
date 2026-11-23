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
    assert 'online ? selectedStyle : OfflineMapStyle.url' in map_view
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
