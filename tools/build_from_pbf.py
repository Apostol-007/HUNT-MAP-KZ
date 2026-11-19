#!/usr/bin/env python3
"""Build a bounded offline raster MBTiles from a locally downloaded OSM PBF.

Requires osmium-tool CLI (osmium extract/export) and Pillow. No map tile server.
This is a bounded regional builder, NOT a whole-country renderer.
"""
import argparse
import json
import shutil
import subprocess
import tempfile
from pathlib import Path
from build_osm_mbtiles import build, tile_bounds

MAX_TILES = 20000
MAX_AREA = 0.25  # degrees squared; guard against huge GeoJSON/raster rendering


def parse_bbox(raw):
    try:
        coords = tuple(float(v.strip()) for v in raw.split(','))
    except ValueError as exc:
        raise ValueError('bbox must be west,south,east,north') from exc
    if len(coords) != 4:
        raise ValueError('bbox must contain exactly four coordinates')
    w, s, e, n = coords
    if not (-180 <= w < e <= 180 and -85.05112878 <= s < n <= 85.05112878):
        raise ValueError('invalid bbox coordinates')
    if (e-w)*(n-s) > MAX_AREA:
        raise ValueError('region too large; split into smaller bbox regions (max 0.25 deg²)')
    return coords


def tile_count(bbox, zmin, zmax):
    if not 0 <= zmin <= zmax <= 17:
        raise ValueError('zoom must be within 0..17')
    count = 0
    for z in range(zmin, zmax + 1):
        x0, x1, y0, y1 = tile_bounds(bbox, z)
        count += (x1-x0+1)*(y1-y0+1)
    return count


def run_command(argv):
    subprocess.run(argv, check=True)


def build_pbf(pbf, output, bbox, zmin, zmax, max_tiles=MAX_TILES, osmium='osmium', keep_geojson=False):
    pbf = Path(pbf).resolve()
    output = Path(output).resolve()
    if not pbf.is_file() or pbf.suffix.lower() != '.pbf':
        raise ValueError('input must be an existing .pbf file')
    if pbf == output:
        raise ValueError('input and output must differ')
    if max_tiles < 1 or tile_count(bbox, zmin, zmax) > max_tiles:
        raise ValueError(f'tile budget exceeded ({max_tiles}); reduce bbox or zoom')
    if not shutil.which(osmium):
        raise ValueError('osmium executable not found; install osmium-tool and add it to PATH')
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='hunt-osm-') as tmp:
        tmp = Path(tmp)
        clipped = tmp / 'region.osm.pbf'
        geojson = tmp / 'region.geojson'
        w, s, e, n = bbox
        # Complete ways is important for roads crossing the selected bbox.
        run_command([osmium, 'extract', '--strategy=complete_ways', '--bbox', f'{w},{s},{e},{n}', '-o', str(clipped), str(pbf)])
        run_command([osmium, 'export', '-f', 'geojson', '-o', str(geojson), str(clipped)])
        # osmium export includes all feature types; retain only relevant map features.
        raw = json.loads(geojson.read_text(encoding='utf-8'))
        if raw.get('type') != 'FeatureCollection':
            raise ValueError('osmium export did not produce a FeatureCollection')
        relevant = ('highway', 'railway', 'waterway', 'water', 'boundary')
        raw['features'] = [f for f in raw.get('features', []) if
                           isinstance(f, dict) and isinstance(f.get('properties'), dict) and
                           (any(k in f['properties'] for k in relevant) or f['properties'].get('natural') == 'water') and
                           f.get('geometry')]
        if not raw['features']:
            raise ValueError('no roads, trails, waterways or boundaries in extracted region')
        geojson.write_text(json.dumps(raw, ensure_ascii=False), encoding='utf-8')
        count = build(geojson, output, bbox, zmin, zmax, max_tiles)
        if keep_geojson:
            shutil.copyfile(geojson, output.with_suffix('.osm-source.geojson'))
        return count, len(raw['features'])


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--pbf', required=True, type=Path, help='local .osm.pbf extract')
    p.add_argument('--bbox', required=True, help='west,south,east,north')
    p.add_argument('--zoom', default='9:14', help='min:max')
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--max-tiles', type=int, default=MAX_TILES)
    p.add_argument('--osmium', default='osmium')
    p.add_argument('--keep-geojson', action='store_true')
    a = p.parse_args()
    try:
        bbox = parse_bbox(a.bbox)
        parts = a.zoom.split(':')
        if len(parts) != 2: raise ValueError('zoom must be min:max')
        zmin, zmax = map(int, parts)
        count, features = build_pbf(a.pbf, a.output, bbox, zmin, zmax, a.max_tiles, a.osmium, a.keep_geojson)
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        p.exit(1, f'PBF build failed: {exc}\n')
    print(f'Created {a.output}: {count} tiles from {features} OSM features')

if __name__ == '__main__':
    main()
