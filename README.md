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

В GitHub: Actions → HUNT MAP KZ - unsigned iOS IPA → Run workflow.
Сборка производится из `iOS/project.yml` и `Core/`; исходники из корня не используются.

## Проверки

```bash
swift test --package-path Core
python -m pip install -r server/requirements.txt pytest httpx
python -m pytest -q server/tests
```

Статус функциональности и ограничения: [мастер-спецификация v4](docs/HUNT_MAP_KZ_v4_MASTER_UI_SPEC_RU.md).
Аудит и удалённые файлы: [отчёт об очистке](docs/REPOSITORY_AUDIT_2026-11-23.md).

Интеграция статических карт и маршрутов: `https://create.web-works.kz/maps/` (для опубликованных пакетов требуется реальное наличие файлов). Генерация IPA и тесты на iPhone должны проверяться по фактическому результату GitHub Actions.

## Protomaps (HUNT MAP KZ v5.4)

Primary vector basemap is **Protomaps Basemap v4 / PMTiles**. The app reads regional `.pmtiles` directly with MapLibre Native, without any raster conversion. Previously imported MBTiles, downloaded GeoJSON routing graphs and map markers remain supported.

1. On Windows run `tools/PREPARE_PROTOMAPS_WINDOWS.bat`. It uses the official `pmtiles extract` CLI to create Almaty grid archives and SHA-256 catalog.
2. Upload **all** output files from `hosting_upload/protomaps/` to `https://create.web-works.kz/maps/protomaps/` (same filenames and paths).
3. Confirm `https://create.web-works.kz/maps/protomaps/catalog.json` returns JSON and individual archives return HTTPS 200.
4. Open the app, select map → grid → download Protomaps; choose offline mode after install. No arbitrary public tile scraping.

The generated style currently displays **geometric basemap features** (roads, tracks, trails, water, forests, buildings) offline; it does **not yet package Protomaps glyphs/sprites for offline text labels and POI icons**. The PMTiles basemap is **not a routable graph**: road navigation still uses separately downloaded, OSM-tagged GeoJSON.

Source data: [Protomaps downloads](https://docs.protomaps.com/basemaps/downloads); [PMTiles CLI](https://docs.protomaps.com/pmtiles/cli). Keep © OpenStreetMap attribution. Satellite imagery is a separate source, not part of Protomaps Basemap.

### Offline Protomaps labels

v5.4.1 includes a separate install operation for local Protomaps label glyph ranges (Latin, Russian and Kazakh Cyrillic) and sprite resources from the public Protomaps basemaps-assets repository. Tap **Скачать подписи и значки** in the grid download manager. This data is saved locally and the Protomaps style switches to local glyph/sprite URLs only when the expected asset set is present. Other scripts/languages and the full upstream Protomaps cartographic style have not yet been packaged; test actual labels on device.
