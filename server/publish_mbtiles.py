"""CLI for publishing already-licensed offline raster MBTiles. No source scraping."""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path

try:
    from .app import PACKS
except ImportError:
    from app import PACKS


def inspect(path: Path) -> dict:
    with sqlite3.connect(f'file:{path.resolve()}?mode=ro', uri=True) as db:
        fmt = db.execute("select value from metadata where name='format'").fetchone()
        count = db.execute('select count(*) from tiles').fetchone()[0]
    if not fmt or fmt[0].lower() not in ('png', 'jpg', 'jpeg', 'webp') or count == 0:
        raise ValueError('Only nonempty raster MBTiles are supported')
    return {'format': fmt[0], 'tile_count': count}


def publish(source: Path, pack_id: str, scope: str, scope_id: str, license: str, version: str, verified=False, dest=None):
    if not pack_id or not all(ch.isascii() and (ch.isalnum() or ch in '-_') for ch in pack_id):
        raise ValueError('Invalid pack ID')
    if scope not in ('region', 'ground', 'country') or not scope_id or not license or not version:
        raise ValueError('Missing metadata')
    inspection = inspect(source)
    folder = Path(dest) if dest else PACKS
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / f'{pack_id}.bin'
    if target.exists():
        raise ValueError('Pack ID already published; use a new versioned ID')
    staging = folder / f'.{pack_id}.tmp'
    h = hashlib.sha256()
    try:
        with source.open('rb') as src, staging.open('xb') as out:
            for block in iter(lambda: src.read(1024 * 1024), b''):
                out.write(block); h.update(block)
        record = dict(pack_id=pack_id, scope=scope, scope_id=scope_id,
                      size_bytes=staging.stat().st_size, sha256=h.hexdigest(),
                      source_version=version, license=license, verified=verified,
                      layers=['raster-mbtiles'])
        catalog_path = folder / 'catalog.json'
        entries = json.loads(catalog_path.read_text()) if catalog_path.exists() else []
        if any(row['pack_id'] == pack_id for row in entries):
            raise ValueError('Already in catalog')
        staging.replace(target)
        temp_catalog = folder / '.catalog.tmp'
        temp_catalog.write_text(json.dumps(entries + [record], indent=2, ensure_ascii=False))
        temp_catalog.replace(catalog_path)
        return record | inspection
    finally:
        staging.unlink(missing_ok=True)


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('--file', type=Path, required=True)
    p.add_argument('--pack-id', required=True)
    p.add_argument('--scope', choices=['region', 'ground', 'country'], required=True)
    p.add_argument('--scope-id', required=True)
    p.add_argument('--license', required=True, help='License proven to allow redistribution/offline use')
    p.add_argument('--version', required=True)
    p.add_argument('--verified', action='store_true', help='Only after independent source/legal verification')
    args = p.parse_args()
    print(json.dumps(publish(args.file, args.pack_id, args.scope, args.scope_id,
                             args.license, args.version, args.verified), indent=2, ensure_ascii=False))
