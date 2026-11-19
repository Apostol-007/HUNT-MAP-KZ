# HUNT MAP KZ v0.8 — импорт границ с контролем источника

## Реализовано

- `server/boundary_ingest.py`: staging и публикация предоставленных оператором GeoJSON полигонов, без подстановки геоданных реальных охотугодий.
- Проверки FeatureCollection, Polygon/MultiPolygon, WGS84, самопересечений (Shapely), количества вершин, уникальности идентификаторов, наличия HTTPS-источника, даты актуальности и лицензии.
- Ограничения: исходный GeoJSON <= 20 МБ, <= 5000 объектов, <= 500000 вершин.
- Удаление произвольных атрибутов из публикуемого файла (allowlist), контроль SHA-256 кандидата, явное решение оператора о публикации.
- `GET /v1/catalog/grounds`, `GET /v1/grounds/{ground_id}`, `GET /v1/grounds/{ground_id}/geojson` с ETag/If-None-Match и проверкой SHA-256.
- Клиентский локальный импорт принимает GeoJSON `Feature` (выдачу API) или `FeatureCollection`. Все границы помечены **юридически не подтверждено** независимо от `boundary_verified` в исходном файле.

## Использование

В каталоге проекта (Python зависимости: `pip install -r server/requirements.txt`):

```bash
python -m server.boundary_ingest stage path/to/grounds.geojson
```

Команда возвращает `candidate_sha256` и путь staging. Перед публикацией **оператор самостоятельно** должен проверить первоисточник, право на распространение и дату юридической актуальности. Эти обстоятельства программно не доказываются.

```bash
python -m server.boundary_ingest publish <candidate_sha256> --approved-by operator-id --license-approved --authority-checked
```

На iPhone можно получить `GET /v1/grounds/<id>/geojson` и импортировать файл через «Загрузки» → «Импортировать границы GeoJSON». Прямое фоновое скачивание границ клиентом в этой версии не реализовано.

Пример входного файла:

```json
{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"ground_id":"TEST-001","name":"Демо (не реальное угодье)","kind":"huntingGround","source_url":"https://example.org/demo","valid_at":"2024-01-01","license":"TEST ONLY"},"geometry":{"type":"Polygon","coordinates":[[[76,43],[77,43],[77,44],[76,44],[76,43]]]}}]}
```

Это **синтетический пример**, не геоданные охотугодья. Для `protectedArea` используйте `kind=protectedArea`.

## Проверка

- `PYTHONPATH=. pytest -q server/tests`: см. `docs/server-test-v0.8.log`.
- `cd Core && swift test`: см. `docs/swift-test-v0.8.log`.
- Исходники iOS не компилировались с Xcode и на реальном iPhone **не тестировались**. Тесты серверного конвейера не подтверждают юридическую точность границ.

## Осталось

- Получить легальные машиночитаемые данные реальных охотугодий и проверить лицензии/актуальность.
- Изменить официальный интерфейс iOS на загрузку подтверждённого каталога границ и версионное обновление без ручного переноса файла.
- Собрать и протестировать Xcode/MapLibre на реальном iPhone (включая строго офлайн-сеть и GPS).
- Добавить область/весь Казахстан для реальных источников, без подстановки случайных карт.
