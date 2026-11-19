#!/usr/bin/env python3
"""Validate and atomically publish a raster MBTiles file to the catalog directory."""
import argparse
import os
import shutil
import sqlite3
import tempfile
from pathlib import Path
from map_catalog_server import PACK_ID


def publish(source, folder):
    source, folder = Path(source), Path(folder)
    if not source.is_file() or source.suffix != '.mbtiles' or not PACK_ID.fullmatch(source.stem):
        raise ValueError('source must be an existing, safely named .mbtiles')
    with sqlite3.connect(f'file:{source.resolve()}?mode=ro', uri=True) as db:
        if db.execute('PRAGMA quick_check').fetchone()[0] != 'ok':
            raise ValueError('SQLite integrity check failed')
        meta = dict(db.execute('SELECT name,value FROM metadata'))
        if meta.get('format') not in ('png', 'jpg', 'jpeg', 'webp') or 'bounds' not in meta:
            raise ValueError('raster MBTiles with bounds required')
        if not db.execute('SELECT 1 FROM tiles LIMIT 1').fetchone():
            raise ValueError('empty map')
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / source.name
    fd, temp = tempfile.mkstemp(prefix='.publishing-', suffix='.mbtiles', dir=folder)
    try:
        with os.fdopen(fd, 'wb') as out, source.open('rb') as inp:
            shutil.copyfileobj(inp, out, 1024 * 1024)
            out.flush(); os.fsync(out.fileno())
        os.replace(temp, target)
    finally:
        if os.path.exists(temp): os.unlink(temp)
    return target


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source', type=Path)
    p.add_argument('--folder', type=Path, default=Path('maps/published'))
    args = p.parse_args()
    try: print('Published:', publish(args.source, args.folder))
    except (ValueError, OSError, sqlite3.Error) as exc: p.exit(1, f'Publish failed: {exc}\n')
