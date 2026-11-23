"""Bounded, actual multi-point Open-Meteo weather forecast sampling.

This is a sampled forecast grid, NOT radar. No contours/particles are rendered by
this service. A mobile renderer must not extrapolate outside the sampled bounds.
"""
from __future__ import annotations
import json
from datetime import datetime, timezone, timedelta
from urllib.parse import urlencode
from urllib.request import urlopen

class WeatherGridError(ValueError):
    pass

VARIABLES = ("wind_speed_10m", "wind_direction_10m", "wind_gusts_10m",
             "pressure_msl", "surface_pressure", "precipitation", "precipitation_probability")


def validate_request(west: float, south: float, east: float, north: float, steps: int, when: datetime):
    if not all(map(__import__('math').isfinite, (west, south, east, north))):
        raise WeatherGridError("Coordinates must be finite")
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        raise WeatherGridError("Invalid bbox or antimeridian crossing; split into separate requests")
    if east - west > 3 or north - south > 3:
        raise WeatherGridError("bbox too large; select a smaller map region")
    if steps < 2 or steps > 4:
        raise WeatherGridError("Grid resolution must be 2..4")
    if when.tzinfo is None:
        raise WeatherGridError("Forecast time must be timezone-aware")
    now = datetime.now(timezone.utc)
    if not now - timedelta(hours=1) <= when <= now + timedelta(days=7):
        raise WeatherGridError("Forecast time outside supported horizon")


def _get_provider_bytes(url: str) -> bytes:
    with urlopen(url, timeout=15) as response:
        if response.status != 200:
            raise WeatherGridError("Provider unavailable")
        data = response.read(1_500_001)
        if len(data) > 1_500_000:
            raise WeatherGridError("Provider response too large")
        return data


def sample_grid(west: float, south: float, east: float, north: float, steps: int,
                when: datetime, fetcher=_get_provider_bytes) -> dict:
    validate_request(west, south, east, north, steps, when)
    points = [(south + (north - south) * y / (steps - 1),
               west + (east - west) * x / (steps - 1))
              for y in range(steps) for x in range(steps)]
    params = {
        "latitude": ",".join(f"{lat:.5f}" for lat, _ in points),
        "longitude": ",".join(f"{lon:.5f}" for _, lon in points),
        "hourly": ",".join(VARIABLES),
        "timezone": "UTC", "forecast_days": "8", "wind_speed_unit": "kmh",
    }
    url = "https://api.open-meteo.com/v1/forecast?" + urlencode(params)
    try:
        response = json.loads(fetcher(url))
    except (ValueError, OSError, UnicodeError) as exc:
        raise WeatherGridError("Weather provider returned invalid response") from exc
    if not isinstance(response, list) or len(response) != len(points):
        raise WeatherGridError("Weather provider did not return all grid points")
    target_hour = when.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:00")
    result = []
    for (lat, lon), entry in zip(points, response):
        hourly = entry.get("hourly") or {}
        hours = hourly.get("time") or []
        if target_hour not in hours:
            raise WeatherGridError("Requested hour unavailable from weather provider")
        ix = hours.index(target_hour)
        values = {}
        for key in VARIABLES:
            sequence = hourly.get(key)
            if not isinstance(sequence, list) or ix >= len(sequence):
                raise WeatherGridError("Missing hourly weather variable")
            value = sequence[ix]
            if value is not None and (not isinstance(value, (int, float)) or
                                      not __import__('math').isfinite(value)):
                raise WeatherGridError("Invalid numeric weather value")
            values[key] = value
        result.append({"latitude": lat, "longitude": lon, **values})
    return {
        "schema": "hunt-weather-grid-v1", "source": "Open-Meteo Forecast API",
        "kind": "model_forecast_not_radar", "forecast_time_utc": target_hour + ":00Z",
        "grid_width": steps, "grid_height": steps,
        "bounds": {"west": west, "south": south, "east": east, "north": north},
        "units": {"wind_speed_10m": "km/h", "wind_gusts_10m": "km/h",
                  "pressure_msl": "hPa", "surface_pressure": "hPa",
                  "precipitation": "mm/hour", "precipitation_probability": "%"},
        "points": result,
    }
