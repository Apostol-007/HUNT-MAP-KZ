#!/usr/bin/env python3
"""Package licensed XYZ raster tiles into offline MBTiles (TMS rows).

Input is an existing XYZ directory z/x/y.png|jpg|webp, exported from a provider
that explicitly permits redistribution and offline storage. No tile scraping.
"""
import argparse
import json
import math
import sqlite3
from pathlib import Path

EXTENSIONS = {'.png': 'png', '.jpg': 'jpg', '.jpeg': 'jpg', '.webp': 'webp'}

def build(source: Path, output: Path, name: str, attribution: str) -> dict:
    if not source.is_dir():
        raise ValueError(f'XYZ directory does not exist: {source}')
    if not attribution.strip():
        raise ValueError('Attribution/license notice is required')
    tiles = []
    formats = set()
    for file in sorted(source.rglob('*')):
        if not file.is_file() or file.suffix.lower() not in EXTENSIONS:
            continue
        parts = file.relative_to(source).parts
        if len(parts) != 3:
            continue
        z, x = int(parts[0]), int(parts[1])
        y = int(file.stem)
        if not (0 <= z <= 22 and 0 <= x < 2 ** z and 0 <= y < 2 ** z):
            raise ValueError(f'Invalid XYZ coordinate: {file}')
        formats.add(EXTENSIONS[file.suffix.lower()])
        tiles.append((z, x, (2 ** z - 1 - y), file))
    if not tiles:
        raise ValueError('No XYZ tiles found')
    if len(formats) != 1:
        raise ValueError('All tiles in one MBTiles must use the same image format')
    if output.exists():
        raise FileExistsError(f'Output already exists: {output}')
    output.parent.mkdir(parents=True, exist_ok=True)
    connection = sqlite3.connect(output)
    try:
        connection.executescript('''CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB,
            PRIMARY KEY (zoom_level, tile_column, tile_row));''')
        meta = {'name': name, 'type': 'baselayer', 'version': '1.0',
                'description': attribution, 'format': formats.pop(),
                'minzoom': str(min(t[0] for t in tiles)), 'maxzoom': str(max(t[0] for t in tiles))}
        connection.executemany('INSERT INTO metadata VALUES (?,?)', meta.items())
        for z, x, tms_y, file in tiles:
            connection.execute('INSERT INTO tiles VALUES (?,?,?,?)', (z, x, tms_y, file.read_bytes()))
        connection.commit()
        result = {'tiles': len(tiles), 'minzoom': meta['minzoom'], 'maxzoom': meta['maxzoom'], 'format': meta['format']}
        if connection.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
            raise ValueError('SQLite integrity check failed')
        return result
    except Exception:
        connection.close()
        output.unlink(missing_ok=True)
        raise
    finally:
        try: connection.close()
        except Exception: pass

if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--xyz', type=Path, required=True, help='Directory with z/x/y.png raster tiles')
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--name', default='Kazakhstan offline raster')
    p.add_argument('--attribution', required=True, help='Source attribution and license notice')
    a = p.parse_args()
    print(json.dumps(build(a.xyz, a.out, a.name, a.attribution), ensure_ascii=False, indent=2))
