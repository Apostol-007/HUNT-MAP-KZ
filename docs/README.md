# HUNT MAP KZ — документация проекта

## v1.6.4 — оптимизация каталогов карт

- Поиск по трем HTTPS-каталогам выполняется конкурентно, вместо последовательных запросов.
- Ограничение ожидания каждого запроса — 12 секунд.
- Отсекаются некорректные координаты, ответы свыше 2 МБ, недопустимые идентификаторы, контрольные суммы и размеры пакетов.
- Удаляются дубликаты внутри одного источника; выдача сортируется детерминированно.
- При недоступности одного источника результаты других сохраняются.
- Никакого скрытого скачивания тайлов Google/Яндекс/OSM.

## Проверка

Linux Swift Package `Core`: 14 XCTest + 8 Swift Testing, успешно 19.11.2026.
Полный iOS target, WidgetKit и поведение на физическом iPhone **не проверены**: для этого нужен macOS/Xcode и подпись.

## Известные ограничения

- Каталоги должны быть настроены и содержать разрешенные к офлайн-использованию MBTiles.
- Пакеты с одинаковым `pack_id` от разных поставщиков могут конфликтовать при локальной установке: необходимо внедрить namespaced storage до одновременной установки таких пакетов.
- Расчет `Track.distanceMeters` проходит по всему массиву точек; при длинных треках требуется инкрементальный счетчик и тесты миграции.
- Необходимо выполнить UI/performance профилирование на iPhone, особенно при длительной GPS-записи.

## v1.6.5 — GPS distance cache and catalog isolation

- New track points update an incremental distance accumulator, avoiding full route-distance scans for every widget refresh. Old saved tracks remain decodable; their distance is computed on demand until a new point is appended.
- Installed remote MBTiles now use a catalog-URL SHA-256 namespace in their filenames, preventing new downloads from different catalogs with identical `pack_id` from overwriting each other. Previously installed unscoped packages are readable through a legacy fallback.
- Remote pack identity and removal use source + pack ID + checksum, not pack ID alone.
- Core tests and Swift syntax parsing performed on Linux. iOS compilation, WidgetKit signing and physical-device tests remain unverified.


## v1.6.6 — GPS persistence
- Append-only track-fixes.jsonl journal with per-fix sync.
- Full atomic route snapshot at most once every 20 seconds during recording, plus lifecycle and state changes.
- Recovery replays journal entries newer than the latest snapshot point; recovered track is stored in history.
- Journal is deleted only after successful full snapshot.
- iOS build and physical-device background/crash tests remain unverified.


## v1.6.7 — отрисовка больших GPS-треков
- Добавлено упрощение полилиний исключительно для отображения на карте (Douglas–Peucker с лимитом 2500 вершин на сегмент).
- Исходные GPS-точки, длина маршрута, навигация и GPX-экспорт не изменяются.
- Разрывы GPS остаются отдельными линиями.
- Тесты Core проверяют сохранение концов, поворотов и длинных маршрутов.
- iOS-компиляция и полевые испытания не проводились.

## v1.6.8 — GPS overlay rendering
- GPS arrow is now maintained separately from route, markers and boundary annotations.
- Static annotations are refreshed only when their drawing signature changes.
- A heading-only update no longer re-simplifies the route or recreates every marker.
- No UI redesign; no change to offline tile sources.
- Validation: Swift parser and HuntCore tests on Linux. iOS compilation and device FPS/battery tests remain unverified.

## v1.6.9 — GPS journal and widget reliability

- Route widget snapshots are rate-limited to once per five seconds during incoming GPS fixes; lifecycle and route-state saves still publish immediately.
- Starting a new recording no longer deletes the previous journal before a successful atomic state snapshot. The journal is cleared only after the snapshot succeeds.
- Journal creation uses iOS file protection `completeFileProtectionUnlessOpen`.
- A corrupted persisted state file is left intact and a diagnostic error is shown instead of silently treating it as an empty database.
- XcodeGen application and widget version/build values are synchronized to 1.6.9 / 169.

Validation: Linux `swift test` passes 11 Swift Testing tests. iOS compilation, GPS background behavior and on-device battery performance remain unverified.


## v1.7.0 — real geographic offline overview

The iOS app bundles `Kazakhstan_Overview_NaturalEarth.mbtiles` (42 raster tiles, zoom levels 3–5, geographical coverage approximately 40–90°E, 40–57°N). It is copied to Application Support on first launch and works without a network connection. The map is derived from the geographic boundary/coastline/rivers datasets distributed with matplotlib Basemap (GSHHS / World Data Bank II). Consult the Basemap datasets' attribution and license terms before redistribution. **This is a low-resolution geographical overview, not a detailed OpenStreetMap map**. It does NOT include 1 m imagery, tracks, streets, hunting-ground borders, or wildlife data. At higher zoom, no new detail appears.

To prepare detailed offline maps legally, acquire an OSM PBF extract (e.g. Geofabrik's Kazakhstan extract), render raster tiles using a self-hosted map renderer (not bulk downloads from public OSM tile servers), package tiles in MBTiles (TMS tile_row; metadata `format=png`, `bounds`, `minzoom`, `maxzoom`) and import from the Downloads screen. Verify data licenses and attribution. No detailed OSM extract was downloadable in the build environment, so none is included.

## v1.7.1 — Создание подробных офлайн-карт из реальных данных OSM

Добавлен `tools/build_osm_mbtiles.py`: локальный генератор **растровых** MBTiles из пользовательского GeoJSON с реальными геометриями OpenStreetMap. Это **не** готовое подробное покрытие Казахстана: подробный набор OSM не включён в ZIP. Встроенная обзорная карта v1.7.0 остаётся без изменений.

### Windows

1. Установить Python 3.11+ и Pillow: `py -m pip install Pillow`.
2. Получить актуальный GeoJSON из OpenStreetMap (например, через экспорт Overpass Turbo для выбранного небольшого района). Убедиться, что в `properties` присутствуют OSM-теги `highway`, `waterway` и т. д. Используйте только данные, которые можно законно перераспространять.
3. Запустить из корня проекта:

```bat
py tools\build_osm_mbtiles.py --geojson almaty-osm.geojson --bbox 76.75,43.10,77.10,43.40 --zoom 9:13 --max-tiles 20000 --output Almaty_OSM.mbtiles
```

4. Перенести MBTiles на iPhone через приложение «Файлы» и импортировать через меню офлайн-карт HUNT MAP KZ.

`--bbox`: запад, юг, восток, север (WGS84); `--zoom`: минимальный и максимальный уровни. Генератор ограничивает число тайлов, чтобы случайно не создать огромный файл. Важно: детализация ограничена исходным GeoJSON. Приближение не создаёт отсутствующие дороги, тропы или спутниковые снимки. Карта содержит только простую схематическую стилизацию объектов и не заменяет полноценный картографический рендерер. При использовании данных OSM сохраняйте атрибуцию © OpenStreetMap contributors и соблюдайте ODbL.

### Тестирование

```bat
cd tools
py -m unittest -v test_build_osm_mbtiles.py
```

4 теста проверяют Web Mercator, генерацию MBTiles, отказ от пустых данных и ограничение числа тайлов. На реальном iPhone и с полной выгрузкой OSM по Казахстану генератор пока не проверен.


## v1.7.2 — загрузка реальных OSM-дорог и троп для небольшого района

Добавлены `tools/fetch_osm_region.py` (Overpass JSON → GeoJSON) и `tools/build_region.py` (полный цикл загрузки и генерации MBTiles). **При наличии интернета на Windows** можно получить настоящие дороги, тропы, железные дороги и водотоки OSM для выбранного небольшого района и создать локальную карту. Сервис Overpass сторонний, доступность не гарантирована. Публичный Overpass не предназначен для массовой загрузки всего Казахстана; площадь запроса ограничена 0.08 градуса². Для областей и всей страны нужен PBF-экстракт и масштабируемый конвейер обработки.

Windows, из корня проекта:

```bat
py -m pip install Pillow
py tools\build_region.py --bbox 76.90,43.20,77.00,43.30 --zoom 9:14 --output Almaty_Small_Area_OSM.mbtiles
```

Команда скачивает реальные OSM-геометрии (требуется интернет), сохраняет исходник рядом с MBTiles как `*.osm-source.geojson`, строит растровые тайлы. Передайте MBTiles на iPhone и импортируйте в приложении. Предел 20 000 тайлов по умолчанию, параметр `--max-tiles` изменяет его. Никаких спутниковых снимков или гарантированного 1 м/пиксель здесь нет. Покрытие троп зависит от полноты OpenStreetMap. Атрибуция: © OpenStreetMap contributors, ODbL.

Проверка: `cd tools && py -m unittest discover -v` (8 тестов). Swift Core — 11 тестов. **Скачивание через Overpass и iOS-сборка в этой среде не проверены; подробная карта в ZIP не включена.** Встроенная обзорная карта Казахстана сохранена.


## v1.7.3 — локальные OSM PBF → региональные MBTiles

Добавлен `tools/build_from_pbf.py`: принимает **заранее скачанный** OSM PBF, вырезает регион через `osmium extract --strategy=complete_ways`, экспортирует GeoJSON через `osmium export` и строит растровый MBTiles существующим генератором. Это конвейер для **небольших регионов**, не полноценный рендерер всей страны. Требуется `osmium-tool` в PATH, Python 3 и Pillow (`py -m pip install Pillow`).

Пример Windows из корня проекта:

```bat
py tools\build_from_pbf.py --pbf kazakhstan-latest.osm.pbf --bbox 76.90,43.20,77.00,43.30 --zoom 9:14 --output Almaty_PBF.mbtiles --keep-geojson
```

PBF необходимо самостоятельно получить из разрешённого источника (например, регионального OSM-экстракта), проверить лицензию и актуальность. Обработка PBF локальная, не требует Overpass. `--bbox` задаётся в порядке west,south,east,north. Ограничение площади 0.25 градуса² и 20 000 тайлов по умолчанию; крупные регионы следует делить. GeoJSON экспорт может потреблять много RAM, поскольку текущий растровый генератор читает объекты целиком; не использовать для всей страны. Атрибуция: © OpenStreetMap contributors, ODbL. Тропы присутствуют только там, где они нанесены в OSM. Спутниковых снимков и разрешения 1 м/пиксель этот конвейер не предоставляет.

Проверка: `cd tools && py -m unittest discover -v` — 13 тестов. Swift Core: 14 XCTest + 11 Swift Testing. **Реальный PBF и `osmium-tool` в текущей среде не проверены; iOS-сборка также не проверена.**

## v1.7.4 — реальные источники карт, автоматическая загрузка PBF, упрощённые настройки

На экране «Загрузки» теперь есть **реальные публичные источники данных**: Geofabrik Kazakhstan, BBBike Kazakhstan и BBBike Extract. Они открываются как официальные страницы загрузки, а не выдаются за совместимые с HUNT MAP KZ API серверы. Пользовательские каталоги `/v1/packs/*`, импорт GeoJSON, диагностика и тестовые опции спрятаны в раскрываемом разделе «Дополнительные настройки и источники». Внешний вид самой карты не изменён.

**Автоматизация Windows** из корня проекта:

```bat
py tools\download_kazakhstan.py --output maps\kazakhstan-latest.osm.pbf
py -m pip install Pillow
py tools\build_from_pbf.py --pbf maps\kazakhstan-latest.osm.pbf --bbox 76.90,43.20,77.00,43.30 --zoom 9:14 --output maps\Almaty_OSM.mbtiles
```

Первая команда скачивает **реальный PBF** с Geofabrik по HTTPS, сохраняет незавершённый файл `.part`, умеет продолжать загрузку через HTTP Range, контролирует размер и печатает SHA-256 после завершения. Вторая команда требует `osmium-tool` в PATH, извлекает небольшой район и создаёт **растровый MBTiles**, совместимый с текущим импортом iOS. Не следует путать сырые PBF, векторные MBTiles и растровые MBTiles. Эти форматы не взаимозаменяемы.

**Ограничения:** приложение не скачивает весь Казахстан в готовом растровом формате прямо с Geofabrik: там опубликованы исходные OSM-данные. Публичные `tile.openstreetmap.org` и `vector.openstreetmap.org` запрещают массовое скачивание офлайн-тайлов. Доступность внешних серверов, выполнение на Windows и сборка iOS должны быть проверены отдельно. Данные OSM не содержат гарантированно всех троп, официальных охотугодий или спутниковых снимков 1 м/пиксель. Атрибуция: © OpenStreetMap contributors, ODbL 1.0.


## v1.7.5 — автоматическая подготовка региональных карт

На Windows запустите `tools\PREPARE_MAP_WINDOWS.bat`. Требуются Python 3, Pillow (скрипт устанавливает при необходимости) и установленный `osmium-tool` в PATH. Скрипт предложит ограниченные области Алматы, Астаны, Шымкента, Караганды и Актобе. Это **примерные прямоугольники городов**, не границы областей и не охотугодья.

Автоматизация: загрузка Geofabrik Kazakhstan `.osm.pbf` с возобновлением, локальная вырезка через osmium, преобразование в растровый MBTiles, проверка SQLite и запись SHA-256/атрибуции в `.manifest.json`. PBF повторно используется из `maps/` при следующих запусках. Для своей территории: `py tools/prepare_offline_map.py --bbox 76.90,43.20,77.00,43.30 --zoom 9:14`. Для существующего PBF: добавьте `--pbf путь\к\kazakhstan-latest.osm.pbf --offline`. Выходной файл `maps/<район>.mbtiles` импортируется в iPhone через «Загрузки».

Ограничения: подготовка происходит на Windows, а не на iPhone; для первой загрузки PBF требуется интернет, а для сборки osmium-tool. Не реализована прямая загрузка готового регионального MBTiles с публичного сервера в приложении. Не входят спутниковые снимки 1 м/пиксель, полная база троп или официальные границы охотугодий. Публичные OSM tile endpoints не используются. Лицензия исходных данных: ODbL 1.0, © OpenStreetMap contributors.

## v1.7.6 — собственный каталог карт с прямой установкой на iPhone

Теперь `tools/map_catalog_server.py` реализует API, с которым уже умеет работать iOS-приложение:

- `GET /v1/packs/at-point?lat=43.25&lon=76.95` — реальные пакеты, покрывающие точку согласно `metadata.bounds`.
- `GET /v1/packs/manifest?scope=region&id=Almaty` — список опубликованных пакетов.
- `GET /v1/packs/{pack_id}` — диапазоны `Range: bytes=start-end`, HTTP 206, `Content-Range`, ETag SHA-256.
- `GET /health` — доступность каталога.

### Автоматизированная публикация

1. На Windows установите Python 3, Pillow и `osmium-tool`; запустите `tools/PREPARE_MAP_WINDOWS.bat` для создания MBTiles из настоящего Geofabrik PBF.
2. Из корня проекта: `py tools/publish_map.py maps/almaty-city.mbtiles`.
3. Запустите `py tools/map_catalog_server.py --maps maps/published`.
4. **Для iPhone обязателен свой HTTPS-домен с TLS-прокси** (например, Caddy или Nginx). Сервер по умолчанию слушает только `127.0.0.1:8765`; это безопасный локальный режим, а не готовый публичный хостинг. Не открывайте его напрямую в интернет.
5. В приложении откройте «Загрузки» → «Дополнительные настройки и источники», укажите HTTPS-адрес своего сервера, выберите точку на карте, найдите пакет и нажмите «Установить карту». После установки файл работает офлайн.

**Ограничения:** сервер не развёрнут в интернете, OSM PBF не скачан в составе этого ZIP, подробные MBTiles не встроены. Сервер публикует **только уже созданные** карты. Встроенная обзорная карта Казахстана остаётся доступной. Источники Geofabrik и BBBike не являются серверами данного API. Не публикуйте файлы, права на распространение которых не проверены. Для данных OSM соблюдайте ODbL и атрибуцию © OpenStreetMap contributors.

## v1.7.7 — загрузка OSM непосредственно на iPhone

Раздел «Загрузки» теперь содержит кнопку получения реальных дорог, троп и водотоков из Overpass API для выбранной на карте точки (или GPS-позиции), радиус 1,5 км. Геометрии сохраняются атомарно в Application Support/OSMOffline/features.json, повторные загрузки объединяются по OSM way ID, и данные рисуются отдельным слоем MapLibre после отключения интернета. Сеть нужна только для первоначального получения объектов. Публичный Overpass может отказать в запросе; максимальное число объектов ограничено. Данные © OpenStreetMap contributors, ODbL 1.0.

**Ограничения:** это линии OSM поверх карты, а не полноценные растровые MBTiles, спутниковая съёмка или гарантированная карта всех троп. Прямое скачивание больших регионов с публичного Overpass намеренно не поддерживается. Для исходного набора всей страны нужен разрешённый региональный дистрибутив. Сборка и испытания на iPhone пока не выполнены.

## v1.7.8 — офлайн-районы непосредственно на iPhone

Раздел «Загрузки» позволяет назвать район, выбрать радиус 500/1000/1500/2500 м и получить дороги, тропы и водотоки напрямую через Overpass API. Каждый район сохраняется отдельно, отображается в списке и может удаляться независимо. Данные v1.7.7 (`OSMOffline/features.json`) сохраняются и читаются без миграции. При загрузке не используются публичные растровые тайловые серверы для массового скачивания.

Ограничения: это векторный слой геометрий OSM, не полноценная базовая карта, не спутниковые снимки и не покрытие всего Казахстана. Первоначальная загрузка требует интернета; Overpass может отказать в обслуживании. На реальном iPhone сборка и фоновая загрузка не проверялись.

## v1.7.9 — сетка загруженных районов

На карте добавлена переключаемая сетка Web Mercator z13. Зелёные контуры обозначают клетки, центр которых попадает в радиус сохранённого OSM-района; серые — клетки без такого покрытия. Сетка включается и выключается кнопкой «Сетка» на карте или через «Слои», выбор сохраняется между запусками. Сетка пересчитывается при перемещении карты, загрузке и удалении районов; при слишком большом охвате (>350 клеток) временно скрывается ради производительности. **Важно:** это индикатор покрытия локально скачанными дорогами/тропами, а не наличия полноценной MBTiles-подложки. Зелёный цвет не гарантирует наличие каждого OSM-объекта в клетке. Размер клетки фиксирован по z13; на мелком масштабе приблизьте карту для отображения.


## v1.7.10 — исправление ошибки Xcode 16.4

По журналу GitHub Actions выявлена ошибка `MainView.swift:126:9: the compiler is unable to type-check this expression in reasonable time`. Большой SwiftUI `GeometryReader` разделён на независимые вычисляемые представления `mapCanvas`, `mapControls`, `mapSideControls`, `mapStatusFooter`, `mapDownloadSheet`. Расположение и функциональность экрана не менялись. Это устранение причины перегрузки type checker, но полноценная сборка iOS должна быть подтверждена GitHub Actions. Предупреждения `CLLocationManagerDelegate` в Swift 5 остаются и требуют отдельного исправления при миграции на Swift 6.

## v1.7.11 — исправление ошибки компиляции SwiftUI

По журналу Xcode 16.4 устранён сбой `MainView.swift:185:21: generic parameter 'V' could not be inferred`: секция загрузки офлайн-карт вынесена в `offlineMapDownloadSection`, а строка пакета — в `offlinePackRow`; неоднозначные цвета заменены на явные `Color`. Для `CLLocationManagerDelegate` добавлена совместимость `@preconcurrency` с текущим `@MainActor` состоянием модели. Проверены Swift Core tests и синтаксический разбор Swift. Полная iOS-компиляция должна быть проверена в GitHub Actions.
