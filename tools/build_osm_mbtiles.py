#!/usr/bin/env python3
"""Raster MBTiles from a REAL, user-supplied OSM GeoJSON export. No network or fake features.

Example: python tools/build_osm_mbtiles.py --geojson almaty-osm.geojson --bbox 76.75,43.10,77.10,43.40 --zoom 9:13 --output almaty.mbtiles
GeoJSON must contain real source geometries; source attribution is mandatory.
"""
import argparse
import json
import math
import sqlite3
from pathlib import Path

MAX_LAT = 85.05112878

def tile_xy(lon, lat, zoom):
    lat = max(-MAX_LAT, min(MAX_LAT, lat))
    n = 2 ** zoom
    x = (lon + 180.0) / 360.0 * n
    y = (1.0 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2.0 * n
    return x, y

def tile_bounds(bbox, zoom):
    west, south, east, north = bbox
    x0, y0 = tile_xy(west, north, zoom)
    x1, y1 = tile_xy(east, south, zoom)
    n = 2 ** zoom
    return max(0, int(math.floor(x0))), min(n-1, int(math.floor(x1))), max(0, int(math.floor(y0))), min(n-1, int(math.floor(y1)))

def geometries(geometry):
    kind = geometry.get('type')
    coordinates = geometry.get('coordinates', [])
    if kind == 'Point':
        yield 'Point', [coordinates]
    elif kind == 'LineString':
        yield 'LineString', coordinates
    elif kind == 'MultiLineString':
        for line in coordinates: yield 'LineString', line
    elif kind == 'Polygon':
        for ring in coordinates: yield 'LineString', ring
    elif kind == 'MultiPolygon':
        for polygon in coordinates:
            for ring in polygon: yield 'LineString', ring
    elif kind == 'GeometryCollection':
        for item in geometry.get('geometries', []): yield from geometries(item)

def feature_style(tags):
    if tags.get('waterway') or tags.get('natural') == 'water': return '#4b9bc4', 3
    if tags.get('highway') in ('motorway', 'trunk', 'primary'): return '#e6a449', 4
    if tags.get('highway') in ('secondary', 'tertiary', 'residential', 'unclassified'): return '#e6d3a1', 3
    if tags.get('highway') in ('track', 'path', 'footway', 'bridleway', 'cycleway'): return '#a87846', 2
    if tags.get('railway'): return '#808080', 2
    if tags.get('boundary'): return '#a7768e', 2
    return '#9aab91', 1

def build(input_path, output_path, bbox, zoom_min, zoom_max, max_tiles):
    from PIL import Image, ImageDraw
    west, south, east, north = bbox
    if not (-180 <= west < east <= 180 and -MAX_LAT <= south < north <= MAX_LAT):
        raise ValueError('Invalid bbox, expected west,south,east,north')
    if not (0 <= zoom_min <= zoom_max <= 17): raise ValueError('Zoom range must be 0..17')
    if input_path.resolve() == output_path.resolve(): raise ValueError('Input and output must differ')
    raw = json.loads(input_path.read_text(encoding='utf-8'))
    if raw.get('type') != 'FeatureCollection': raise ValueError('Expected GeoJSON FeatureCollection')
    features = raw.get('features', [])
    if not features: raise ValueError('Empty GeoJSON: refusing to generate blank map')
    plans = []
    for zoom in range(zoom_min, zoom_max + 1):
        x0, x1, y0, y1 = tile_bounds(bbox, zoom)
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                plans.append((zoom, x, y))
                if len(plans) > max_tiles: raise ValueError(f'Tile budget exceeded ({max_tiles}); use smaller bbox/zoom')
    if not plans: raise ValueError('No tiles selected')
    import io
    output_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = output_path.with_suffix('.building.mbtiles')
    if tmp.exists(): tmp.unlink()
    connection = sqlite3.connect(tmp)
    try:
        connection.executescript('CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT); CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB, UNIQUE(zoom_level,tile_column,tile_row));')
        metadata = {'name': input_path.stem + ' OSM offline', 'type': 'baselayer', 'version': '1', 'format': 'png', 'minzoom': str(zoom_min), 'maxzoom': str(zoom_max), 'bounds': ','.join(map(str, bbox)), 'attribution': '© OpenStreetMap contributors (ODbL); derived from user-supplied GeoJSON'}
        connection.executemany('INSERT INTO metadata VALUES (?,?)', metadata.items())
        for zoom, tx, ty in plans:
            canvas = Image.new('RGB', (256, 256), '#edf0e6')
            draw = ImageDraw.Draw(canvas)
            for feature in features:
                tags = feature.get('properties') or {}
                color, width = feature_style(tags)
                geometry = feature.get('geometry') or {}
                for kind, coords in geometries(geometry):
                    points = []
                    for point in coords:
                        if len(point) < 2: continue
                        x, y = tile_xy(float(point[0]), float(point[1]), zoom)
                        points.append(((x - tx) * 256, (y - ty) * 256))
                    if kind == 'Point' and points:
                        x, y = points[0]
                        if -4 <= x <= 260 and -4 <= y <= 260: draw.ellipse((x-2,y-2,x+2,y+2), fill=color)
                    elif len(points) >= 2:
                        # Pillow clips lines outside the image; skip extremely distant shapes.
                        if max(p[0] for p in points) < -5 or min(p[0] for p in points) > 261 or max(p[1] for p in points) < -5 or min(p[1] for p in points) > 261: continue
                        draw.line(points, fill=color, width=width, joint='curve')
            buf = io.BytesIO()
            canvas.save(buf, format='PNG', optimize=True)
            connection.execute('INSERT INTO tiles VALUES (?,?,?,?)', (zoom, tx, 2**zoom-1-ty, buf.getvalue()))
        connection.commit()
        check = connection.execute('PRAGMA integrity_check').fetchone()[0]
        if check != 'ok': raise RuntimeError('MBTiles SQLite integrity failed: ' + check)
    except BaseException:
        connection.close()
        tmp.unlink(missing_ok=True)
        raise
    connection.close()
    tmp.replace(output_path)
    return len(plans)

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--geojson', required=True, type=Path)
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--bbox', required=True, help='west,south,east,north in WGS84')
    p.add_argument('--zoom', default='9:13', help='min:max')
    p.add_argument('--max-tiles', type=int, default=20000)
    a = p.parse_args()
    bbox = tuple(map(float, a.bbox.split(',')))
    if len(bbox) != 4: p.error('--bbox requires four numbers')
    zmin, zmax = map(int, a.zoom.split(':'))
    count = build(a.geojson, a.output, bbox, zmin, zmax, a.max_tiles)
    print(f'Created {a.output} ({count} real-source raster tiles). Import .mbtiles in HUNT MAP KZ.')

if __name__ == '__main__': main()
