# HUNT MAP KZ v3.1 — встроенный MapTiler ключ (без ручного ввода)

**Базовая версия:** v3.0, установленная в GitHub. ZIP содержит только изменённые и новые файлы. Сохраняйте пути при замене.

## Один раз в GitHub

1. Откройте свой репозиторий GitHub → Settings → Secrets and variables → Actions.
2. Нажмите **New repository secret**.
3. Название: `MAPTILER_API_KEY`.
4. Значение: **актуальный MapTiler API Key** (не загружайте ключ в репозиторий и не публикуйте в чат).
5. Запустите Actions → **HUNT MAP KZ - unsigned iOS IPA** → Run workflow.

Workflow встраивает ключ в Info.plist на этапе Xcode. Поле ручного ввода удалено. Ключ начинает работать в новой IPA автоматически.

**Важно:** ключ MapTiler в IPA можно извлечь, поэтому это не секрет в криптографическом смысле. Создайте отдельный ключ для приложения, ограничьте User-Agent, если подтверждён на реальных запросах, задайте квоты и отслеживайте использование. Если API key ранее публиковался в ссылке/чате, перевыпустите его.

## Что менялось
- `iOS/HuntMap/MapTilerConfiguration.swift` — **новый**, читает ключ из Info.plist.
- `iOS/HuntMap/OfflineMapView.swift` — получает ключ без AppStorage/ручного ввода.
- `iOS/HuntMap/MainView.swift` — нет поля SecureField для API key, отображается статус подключения.
- `iOS/project.yml` — Info.plist build setting, версия 3.1.0.
- `.github/workflows/ios-unsigned-ipa.yml` — build-time ключ и проверка Info.plist, без печати значения.

## Проверки и ограничения
Локальные тесты HuntCore/API не компилируют iOS target. Полную сборку MapLibre + SwiftUI и факт получения MapTiler-карт должен подтвердить GitHub Actions и тест на iPhone.
