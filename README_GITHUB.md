# HUNT MAP KZ v2.4 — GitHub исходники

Погодные слои: интерполированная сетка, векторные стрелки ветра, расчётные изобары давления, выбор времени +0…+48 ч, русские легенды и контроль достоверности; требуется собственный HTTPS-сервер API. Компиляция полного iOS-приложения не подтверждена.

# HUNT MAP KZ

Offline-first iOS hunting navigation prototype for Kazakhstan: MapLibre online OpenFreeMap preview, user-provided offline MBTiles, GPS track recording, markers, GeoJSON boundary import, GBIF Kazakhstan species discovery, optional FastAPI pack server, and shake-to-export privacy-redacted diagnostics.

**Project owner / initiator:** Николай Олегович Мякшин (Алматы, Казахстан).

## Start here

- Windows -> GitHub Actions unsigned IPA: [`docs/GITHUB_IPA_WINDOWS_RU.md`](docs/GITHUB_IPA_WINDOWS_RU.md)
- Source: `iOS/HuntMap` + `Core` + `server`
- Workflow: `.github/workflows/ios-unsigned.yml`
- Server tests: `python -m pytest server/tests -q`
- Swift core tests: `cd Core && swift test`

## Boundaries and wildlife are not permits

No verified nationwide hunting boundary dataset or licensed 1 m satellite imagery is bundled. GeoJSON import accepts user-supplied geographic data; legal authenticity remains unverified. GBIF provides observations, not hunting permissions. The OpenFreeMap basemap requires network. Offline MBTiles must be supplied or published under compatible terms. Never bulk-download public OSM tiles.

## Release maturity

**2.4 source candidate, unverified on physical iPhone.** GitHub build must run successfully before installing; diagnostics and shake behavior need device tests. Do not rely solely on this app for legal boundary decisions or safety.
