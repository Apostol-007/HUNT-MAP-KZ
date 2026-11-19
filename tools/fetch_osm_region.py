#!/usr/bin/env python3
"""Fetch real OSM ways for a small bounding box from Overpass and export GeoJSON.

Requires internet; do not use for whole-country bulk extracts. For large areas use
an OSM PBF extract and a dedicated tile pipeline. No fabricated map features.
"""
import argparse
import json
import math
import urllib.parse
import urllib.request
from pathlib import Path

DEFAULT_API = 'https://overpass.kumi.systems/api/interpreter'
MAX_AREA_DEG2 = 0.08
TAGS = ('highway', 'waterway', 'railway', 'boundary')

def validate_bbox(bbox):
    if len(bbox) != 4 or not all(math.isfinite(v) for v in bbox):
        raise ValueError('bbox must have four finite numbers')
    west, south, east, north = bbox
    if not (-180 <= west < east <= 180 and -85 <= south < north <= 85):
        raise ValueError('invalid bbox')
    if (east-west)*(north-south) > MAX_AREA_DEG2:
        raise ValueError('area too large for public Overpass; split into small regions or use a PBF extract')

def query_for(bbox):
    validate_bbox(bbox)
    w,s,e,n = bbox
    bounds = f'({s},{w},{n},{e})'
    return '[out:json][timeout:90];(' + ''.join(f'way["{key}"]{bounds};' for key in TAGS) + ');out geom;'

def to_geojson(data):
    if not isinstance(data, dict) or not isinstance(data.get('elements'), list):
        raise ValueError('expected Overpass JSON elements')
    features = []
    seen = set()
    for el in data['elements']:
        if not isinstance(el, dict) or el.get('type') != 'way':
            continue
        ident = el.get('id')
        if not isinstance(ident, int) or ident in seen:
            continue
        seen.add(ident)
        tags = el.get('tags') or {}
        if not isinstance(tags, dict) or not any(k in tags for k in TAGS):
            continue
        geometry = el.get('geometry') or []
        if len(geometry) < 2:
            continue
        points = []
        for p in geometry:
            try:
                lon, lat = float(p['lon']), float(p['lat'])
            except (KeyError, ValueError, TypeError):
                points = []
                break
            if not math.isfinite(lon) or not math.isfinite(lat) or not (-180 <= lon <= 180 and -90 <= lat <= 90):
                points = []
                break
            points.append([lon, lat])
        if len(points) < 2:
            continue
        features.append({'type':'Feature', 'id':f'way/{ident}', 'properties':tags,
                         'geometry':{'type':'LineString','coordinates':points}})
    return {'type':'FeatureCollection', 'features':features}

def fetch(bbox, output, api=DEFAULT_API, timeout=120):
    validate_bbox(bbox)
    url = urllib.parse.urlparse(api)
    if url.scheme != 'https' or not url.netloc or url.username or url.password:
        raise ValueError('Overpass API URL must use HTTPS')
    body = urllib.parse.urlencode({'data':query_for(bbox)}).encode('ascii')
    request = urllib.request.Request(api, data=body, headers={'User-Agent':'HuntMapKZ-OfflineMapBuilder/1.7.2', 'Content-Type':'application/x-www-form-urlencoded'}, method='POST')
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read(60_000_001)
    if len(raw) > 60_000_000:
        raise ValueError('Overpass response too large; use a smaller area')
    result = to_geojson(json.loads(raw))
    if not result['features']:
        raise ValueError('No matching OSM features; refusing to create empty map')
    output.parent.mkdir(parents=True, exist_ok=True)
    temp = output.with_suffix('.partial.geojson')
    try:
        temp.write_text(json.dumps(result, ensure_ascii=False, separators=(',',':')), encoding='utf-8')
        temp.replace(output)
    finally:
        temp.unlink(missing_ok=True)
    return len(result['features'])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bbox', required=True, help='west,south,east,north (small area)')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--api', default=DEFAULT_API)
    args = parser.parse_args()
    try:
        bbox = tuple(float(v) for v in args.bbox.split(','))
        count = fetch(bbox, args.output, args.api)
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        parser.exit(1, f'OSM download failed: {exc}\n')
    print(f'Exported {count} real OSM ways to {args.output}. Attribution: © OpenStreetMap contributors (ODbL).')

if __name__ == '__main__': main()
