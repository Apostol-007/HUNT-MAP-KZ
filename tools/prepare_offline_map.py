#!/usr/bin/env python3
"""One-command, bounded, resumable OSM -> raster MBTiles workflow for Windows/Linux.

The source is Geofabrik OSM PBF, not public map tile servers.
"""
import argparse
import json
import sqlite3
import sys
from pathlib import Path

from build_from_pbf import build_pbf, parse_bbox, tile_count
from download_kazakhstan import download, sha256

# Example areas only, not administrative region polygons or hunting-ground boundaries.
PRESETS = {
    'almaty-city': (76.85, 43.18, 77.05, 43.32),
    'astana-city': (71.32, 51.08, 71.55, 51.24),
    'shymkent-city': (69.45, 42.26, 69.70, 42.44),
    'karaganda-city': (73.00, 49.72, 73.28, 49.90),
    'aktobe-city': (57.05, 50.20, 57.35, 50.40),
}

def validate_mbtiles(path: Path):
    with sqlite3.connect(f'file:{path.resolve()}?mode=ro', uri=True) as db:
        result = db.execute('PRAGMA quick_check').fetchone()[0]
        if result != 'ok':
            raise ValueError('MBTiles SQLite integrity failed: ' + str(result))
        names = {r[0]: r[1] for r in db.execute('SELECT name,value FROM metadata')}
        if names.get('format') != 'png':
            raise ValueError('expected PNG raster MBTiles')
        count = db.execute('SELECT count(*) FROM tiles').fetchone()[0]
        if count <= 0:
            raise ValueError('empty MBTiles')
        return count

def prepare(*, preset=None, bbox=None, pbf=None, output=None, cache=None, zmin=9, zmax=14,
            max_tiles=20000, offline=False, osmium='osmium'):
    if (preset is None) == (bbox is None):
        raise ValueError('specify exactly one of --preset or --bbox')
    bounds = PRESETS[preset] if preset else parse_bbox(bbox)
    if tile_count(bounds, zmin, zmax) > max_tiles:
        raise ValueError('tile budget exceeded; reduce region or zoom')
    cache = Path(cache or 'maps/kazakhstan-latest.osm.pbf')
    if pbf:
        source = Path(pbf)
        if not source.is_file():
            raise FileNotFoundError(source)
    else:
        source = cache
        if not source.is_file():
            if offline:
                raise ValueError('offline mode requires existing --pbf or cached extract')
            print('Downloading Kazakhstan OSM extract from Geofabrik (resumable)...', flush=True)
            download(source)
    target = Path(output or f'maps/{preset or "custom-region"}.mbtiles')
    if source.resolve() == target.resolve():
        raise ValueError('source and output must differ')
    # Atomic publication: an interrupted render never replaces a valid installed pack.
    staging = target.with_name(target.name + '.building.mbtiles')
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        staging.unlink(missing_ok=True)
        generated, features = build_pbf(source, staging, bounds, zmin, zmax, max_tiles, osmium)
        actual = validate_mbtiles(staging)
        if actual != generated:
            raise ValueError('tile count mismatch')
        staging.replace(target)
    finally:
        staging.unlink(missing_ok=True)
    manifest = {
        'file': target.name, 'source': 'Geofabrik / OpenStreetMap',
        'license': 'ODbL 1.0 (attribution required)', 'bbox': list(bounds),
        'zoom': [zmin, zmax], 'tiles': actual, 'features': features,
        'bytes': target.stat().st_size, 'sha256': sha256(target),
        'pbf': str(source),
    }
    target.with_suffix('.manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding='utf-8')
    print(f'Ready: {target} | {actual} tiles | {target.stat().st_size:,} bytes')
    print('Copy/import the .mbtiles file into HUNT MAP KZ on iPhone.')
    return manifest

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--preset', choices=sorted(PRESETS))
    group.add_argument('--bbox', help='west,south,east,north; bounded to 0.25 square degrees')
    parser.add_argument('--pbf', type=Path, help='existing local Kazakhstan .osm.pbf; skips download')
    parser.add_argument('--cache', type=Path, default=Path('maps/kazakhstan-latest.osm.pbf'))
    parser.add_argument('--output', type=Path)
    parser.add_argument('--zoom', default='9:14')
    parser.add_argument('--max-tiles', type=int, default=20000)
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--osmium', default='osmium')
    args = parser.parse_args()
    try:
        parts = args.zoom.split(':')
        if len(parts) != 2:
            raise ValueError('--zoom must be min:max')
        zmin, zmax = map(int, parts)
        prepare(preset=args.preset, bbox=args.bbox, pbf=args.pbf, output=args.output,
                cache=args.cache, zmin=zmin, zmax=zmax, max_tiles=args.max_tiles,
                offline=args.offline, osmium=args.osmium)
    except (ValueError, OSError, RuntimeError) as exc:
        parser.exit(1, f'Offline map preparation failed: {exc}\n')

if __name__ == '__main__':
    main()
