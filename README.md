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
