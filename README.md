# HUNT MAP KZ

Нативное iOS-приложение для полевой навигации на базе SwiftUI и MapLibre.

## Актуальная структура

- `iOS/HuntMap/` — исходники iOS-приложения
- `iOS/project.yml` — конфигурация XcodeGen
- `Core/` — Swift Package HuntCore и тесты
- `server/` — Python API и тесты
- `tools/`, `scripts/` — утилиты подготовки карт и проверки
- `maps/`, `hosting_upload/` — картографические примеры и пакеты
- `docs/` — документация, визуальный эталон и отчёт об аудите
- `.github/workflows/ios-unsigned-ipa.yml` — единственный активный CI workflow

## Сборка

В GitHub: Actions → HUNT MAP KZ - unsigned iOS IPA → Run workflow. Обычные push запускают Linux-тесты; IPA на macOS запускается только вручную либо для коммита с `[release]` в сообщении.
Сборка производится из `iOS/project.yml` и `Core/`; исходники из корня не используются.

## Проверки

```bash
swift test --package-path Core
python -m pip install -r server/requirements.txt -r tools/requirements.txt pytest httpx
PYTHONPATH=tools python -m pytest -q server/tests tools/test_*.py
python scripts/verify_iphone_layout.py
python scripts/check_ui_structure.py
```

Актуальный аудит оптимизации и критерии приёмки: [OPTIMIZATION_RELEASE_2026-11-24](docs/OPTIMIZATION_RELEASE_2026-11-24.md). Исторический статус: [IMPLEMENTATION_STATUS](docs/IMPLEMENTATION_STATUS.md). Мастер-спецификация UI: [v4](docs/HUNT_MAP_KZ_v4_MASTER_UI_SPEC_RU.md).
Аудит и удалённые файлы: [отчёт об очистке](docs/REPOSITORY_AUDIT_2026-11-23.md).

Интеграция статических карт и маршрутов: `https://create.web-works.kz/maps/` (для опубликованных пакетов требуется реальное наличие файлов). Генерация IPA и тесты на iPhone должны проверяться по фактическому результату GitHub Actions.

## Protomaps (HUNT MAP KZ v5.4)

Protomaps Basemap v4 / PMTiles is an optional regional vector source. The generated MapLibre style refers to the `pmtiles://` scheme; **actual decoding and display of PMTiles on physical iPhone is not yet verified**. The app still supports raster MBTiles, GeoJSON routing, and local markers. Do not consider the number of downloaded PMTiles equivalent to successful rendering.

1. On Windows run `tools/PREPARE_PROTOMAPS_WINDOWS.bat`. It uses the official `pmtiles extract` CLI to create Almaty grid archives and SHA-256 catalog.
2. Upload **all** output files from `hosting_upload/protomaps/` to `https://create.web-works.kz/maps/protomaps/` (same filenames and paths).
3. Confirm `https://create.web-works.kz/maps/protomaps/catalog.json` returns JSON and individual archives return HTTPS 200.
4. Open the app, select map → grid → download Protomaps; choose offline mode after install. No arbitrary public tile scraping.

The generated style currently displays **geometric basemap features** (roads, tracks, trails, water, forests, buildings) offline; it does **not yet package Protomaps glyphs/sprites for offline text labels and POI icons**. The PMTiles basemap is **not a routable graph**: road navigation still uses separately downloaded, OSM-tagged GeoJSON.

Source data: [Protomaps downloads](https://docs.protomaps.com/basemaps/downloads); [PMTiles CLI](https://docs.protomaps.com/pmtiles/cli). Keep © OpenStreetMap attribution. Satellite imagery is a separate source, not part of Protomaps Basemap.

### Offline Protomaps labels

v5.4.1 includes a separate install operation for local Protomaps label glyph ranges (Latin, Russian and Kazakh Cyrillic) and sprite resources from the public Protomaps basemaps-assets repository. Tap **Скачать подписи и значки** in the grid download manager. This data is saved locally and the Protomaps style switches to local glyph/sprite URLs only when the expected asset set is present. Other scripts/languages and the full upstream Protomaps cartographic style have not yet been packaged; test actual labels on device.

## Valhalla local routing & saved track replay (v5.7)

Valhalla Mobile 0.6.6 is embedded as a native iOS dependency. The app **never queries a remote routing server** for navigation. It first uses a Valhalla C++ engine with the previously downloaded `valhalla_tiles.tar` (walking = `pedestrian`, driving = `auto`). If local tiles are missing or Valhalla cannot route, it attempts the existing tagged GeoJSON offline graph. No straight-line fallback.

### Build and install routing tiles on Windows

Run `tools/PREPARE_VALHALLA_WINDOWS.bat` with Docker Desktop running. It uses the **official** `ghcr.io/valhalla/valhalla-scripted:latest` image and Geofabrik Kazakhstan OSM extract. It creates `hosting_upload/valhalla/valhalla_tiles.tar` and matching SHA-256 `catalog.json`. This needs substantial free disk, RAM and internet access on Windows. Do **not** rename a Protomaps PMTiles archive to TAR: the formats are unrelated.

Upload both files to `https://create.web-works.kz/maps/valhalla/`. In the iOS app open **Маршруты → Valhalla → Скачать** or **Импорт TAR** for a locally transferred archive. The app verifies size and SHA-256 of hosted downloads before installation. File-based Valhalla routing is then entirely offline. The app does not currently implement automatic downloads of regional graph subsets or turn-by-turn voice commands.

### Recorded route playback

Every stored GPS track in **Данные → Маршруты** has actions **Показать на карте**, **Воспроизвести: от начала / от конца**, **Пройти от начала / от конца**. MapLibre draws the original recorded points; playback animates a pin across them. Follow mode monitors GPS against the recorded geometry and displays remaining length and off-route deviation. It is a faithful replay of a GPS track, **not** proof that every segment is traversable now or legally accessible.
