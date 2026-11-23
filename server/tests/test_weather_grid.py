from datetime import datetime, timezone, timedelta
import json
import pytest
from server.weather_grid import sample_grid, validate_request, WeatherGridError, VARIABLES


def test_rejects_excessive_bbox():
    with pytest.raises(WeatherGridError):
        validate_request(70, 40, 90, 50, 4, datetime.now(timezone.utc))


def test_rejects_crossing_antimeridian_until_split():
    with pytest.raises(WeatherGridError):
        validate_request(179, 42, -179, 43, 3, datetime.now(timezone.utc))


def test_rejects_unbounded_grid():
    with pytest.raises(WeatherGridError):
        validate_request(76, 43, 77, 44, 999, datetime.now(timezone.utc))


def test_grid_returns_actual_hour_and_unmodified_provider_values():
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    hour = now.strftime('%Y-%m-%dT%H:00')
    queries = []
    def mock_fetch(url):
        queries.append(url)
        row = {"hourly": {"time": [hour], **{v: [i+1.0] for i, v in enumerate(VARIABLES)}}}
        return json.dumps([row for _ in range(9)]).encode()
    result = sample_grid(76.0, 43.0, 77.0, 44.0, 3, now, fetcher=mock_fetch)
    assert len(result['points']) == 9
    assert result['grid_width'] == 3
    assert result['points'][0]['latitude'] == 43.0
    assert result['points'][8]['longitude'] == 77.0
    assert result['points'][0]['precipitation'] == 6.0
    assert result['kind'] == 'model_forecast_not_radar'
    assert len(queries) == 1


def test_missing_hour_or_grid_point_rejected():
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    with pytest.raises(WeatherGridError):
        sample_grid(76, 43, 77, 44, 2, now, fetcher=lambda _: b'[]')


def test_missing_values_preserved_as_null():
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    hour = now.strftime('%Y-%m-%dT%H:00')
    payload = [{"hourly": {"time": [hour], **{v: [None] for v in VARIABLES}}} for _ in range(4)]
    value = sample_grid(76, 43, 77, 44, 2, now, fetcher=lambda _: json.dumps(payload).encode())
    assert value['points'][0]['wind_speed_10m'] is None


def test_four_by_four_weather_nodes_preserve_order_and_units():
    now = datetime.now(timezone.utc).replace(minute=0, second=0, microsecond=0)
    hour = now.strftime('%Y-%m-%dT%H:00')
    sample = {"hourly": {"time": [hour], **{v: [4.5] for v in VARIABLES}}}
    value = sample_grid(76, 42, 77, 43, 4, now,
                        fetcher=lambda _: json.dumps([sample] * 16).encode())
    assert len(value['points']) == 16
    assert value['points'][0]['latitude'] == 42.0
    assert value['points'][15]['latitude'] == 43.0
    assert value['points'][15]['longitude'] == 77.0
    assert value['units']['precipitation'] == 'mm/hour'
    assert value['units']['wind_speed_10m'] == 'km/h'
