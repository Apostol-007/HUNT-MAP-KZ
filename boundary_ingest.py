"""Stage and publish user-supplied GeoJSON boundaries with explicit provenance.

This utility validates geometry and metadata. It does NOT verify legal title or
claim that any submitted polygon is an authoritative hunting boundary.
Only an operator making an explicit approval decision can publish a candidate.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from datetime import date
from pathlib import Path
from urllib.parse import urlparse

from shapely.geometry import shape, mapping

MAX_INPUT = 20_000_000
MAX_FEATURES = 5000
MAX_VERTICES = 500_000
ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}\Z')
ALLOWED_KINDS = {'huntingGround', 'protectedArea'}


def _read_json(path: Path):
    if not path.is_file() or path.stat().st_size > MAX_INPUT:
        raise ValueError('GeoJSON missing or exceeds 20 MB')
    return json.loads(path.read_text(encoding='utf-8'))


def _ring_vertices(geometry):
    polygons = [geometry] if geometry.geom_type == 'Polygon' else list(geometry.geoms)
    count = 0
    for polygon in polygons:
        count += len(polygon.exterior.coords)
        for ring in polygon.interiors:
            count += len(ring.coords)
    return count


def _source_url(value):
    if not isinstance(value, str) or len(value) > 1500:
        return False
    parsed = urlparse(value)
    return parsed.scheme == 'https' and bool(parsed.hostname) and not parsed.username and not parsed.password


def validate_collection(raw):
    if not isinstance(raw, dict) or raw.get('type') != 'FeatureCollection':
        raise ValueError('expected FeatureCollection')
    features = raw.get('features')
    if not isinstance(features, list) or not (1 <= len(features) <= MAX_FEATURES):
        raise ValueError('feature count must be 1..5000')
    result, ids = [], set()
    total_vertices = 0
    for i, feature in enumerate(features):
        if not isinstance(feature, dict) or feature.get('type') != 'Feature':
            raise ValueError(f'feature {i}: not GeoJSON Feature')
        props = feature.get('properties')
        if not isinstance(props, dict):
            raise ValueError(f'feature {i}: missing properties')
        identifier = props.get('ground_id')
        name = props.get('name')
        kind = props.get('kind')
        source = props.get('source_url')
        legal_date = props.get('valid_at')
        license_name = props.get('license')
        if not isinstance(identifier, str) or not ID.fullmatch(identifier) or identifier in ids:
            raise ValueError(f'feature {i}: missing/duplicate/unsafe ground_id')
        ids.add(identifier)
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 200:
            raise ValueError(f'feature {i}: invalid name')
        if kind not in ALLOWED_KINDS:
            raise ValueError(f'feature {i}: invalid kind')
        if not _source_url(source):
            raise ValueError(f'feature {i}: HTTPS source_url required')
        try:
            if not isinstance(legal_date, str) or date.fromisoformat(legal_date) > date.today():
                raise ValueError()
        except ValueError:
            raise ValueError(f'feature {i}: valid_at must be a past ISO date') from None
        if not isinstance(license_name, str) or not 1 <= len(license_name.strip()) <= 200:
            raise ValueError(f'feature {i}: license required')
        try:
            geo = shape(feature['geometry'])
        except (ValueError, TypeError, KeyError, AttributeError) as exc:
            raise ValueError(f'feature {i}: invalid geometry') from exc
        if geo.geom_type not in ('Polygon', 'MultiPolygon') or geo.is_empty or not geo.is_valid:
            raise ValueError(f'feature {i}: invalid polygon, self intersection or empty geometry')
        total_vertices += _ring_vertices(geo)
        if total_vertices > MAX_VERTICES:
            raise ValueError('too many vertices')
        polygons = [geo] if geo.geom_type == 'Polygon' else geo.geoms
        for polygon in polygons:
            for ring in [polygon.exterior, *polygon.interiors]:
                for coord in ring.coords:
                    lon, lat = coord[:2]
                    if not (-180 <= lon <= 180 and -90 <= lat <= 90):
                        raise ValueError(f'feature {i}: coordinates outside WGS84')
        # Only allowlisted properties cross the publication boundary.
        result.append({'type': 'Feature', 'properties': {
            'ground_id': identifier, 'name': name.strip(), 'kind': kind,
            'source_url': source, 'valid_at': legal_date, 'license': license_name.strip(),
            'boundary_verified': False,
        }, 'geometry': mapping(geo)})
    return {'type': 'FeatureCollection', 'features': result}


def _canonical(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False).encode('utf-8')


def stage(path: Path, staging_dir: Path):
    obj = validate_collection(_read_json(path))
    data = _canonical(obj)
    digest = hashlib.sha256(data).hexdigest()
    staging_dir.mkdir(parents=True, exist_ok=True)
    destination = staging_dir / f'{digest}.json'
    if not destination.exists():
        destination.write_bytes(data)
    return {'candidate_sha256': digest, 'feature_count': len(obj['features']), 'file': str(destination),
            'status': 'STAGED_NOT_LEGALLY_VERIFIED'}


def publish(staged_sha256: str, staging_dir: Path, published_dir: Path, *, approved_by: str,
            license_approved: bool, authority_checked: bool):
    if not re.fullmatch('[0-9a-f]{64}', staged_sha256):
        raise ValueError('invalid candidate hash')
    if not license_approved or not authority_checked or not approved_by.strip():
        raise ValueError('explicit legal/source review and operator identity required')
    staged_path = staging_dir / f'{staged_sha256}.json'
    data = staged_path.read_bytes()
    if hashlib.sha256(data).hexdigest() != staged_sha256:
        raise ValueError('staged file modified since review')
    obj = validate_collection(json.loads(data))
    published_dir.mkdir(parents=True, exist_ok=True)
    index_path = published_dir / 'catalog.json'
    index = json.loads(index_path.read_text('utf-8')) if index_path.exists() else []
    by_id = {item['ground_id']: item for item in index}
    for feature in obj['features']:
        props = feature['properties']
        # The application must not infer legal accuracy from this operational approval.
        individual = _canonical(feature)
        digest = hashlib.sha256(individual).hexdigest()
        dest = published_dir / f'{digest}.geojson'
        if not dest.exists():
            dest.write_bytes(individual)
        by_id[props['ground_id']] = {
            'ground_id': props['ground_id'], 'name': props['name'], 'kind': props['kind'],
            'source_url': props['source_url'], 'valid_at': props['valid_at'],
            'license': props['license'], 'sha256': digest,
            'operator_reviewed': True, 'boundary_verified': False,
        }
    tmp = index_path.with_suffix('.tmp')
    tmp.write_bytes(_canonical(sorted(by_id.values(), key=lambda x: x['ground_id'])))
    os.replace(tmp, index_path)
    return {'published': len(obj['features']), 'status': 'OPERATOR_REVIEWED_LEGAL_VALIDITY_NOT_GUARANTEED'}


def main():
    parser = argparse.ArgumentParser(description='HUNT MAP KZ boundary ingestion')
    sub = parser.add_subparsers(dest='command', required=True)
    s = sub.add_parser('stage'); s.add_argument('geojson'); s.add_argument('--staging', default='server/boundary_staging')
    p = sub.add_parser('publish'); p.add_argument('sha256'); p.add_argument('--staging', default='server/boundary_staging')
    p.add_argument('--published', default='server/boundaries'); p.add_argument('--approved-by', required=True)
    p.add_argument('--license-approved', action='store_true'); p.add_argument('--authority-checked', action='store_true')
    args = parser.parse_args()
    if args.command == 'stage':
        result = stage(Path(args.geojson), Path(args.staging))
    else:
        result = publish(args.sha256, Path(args.staging), Path(args.published), approved_by=args.approved_by,
                         license_approved=args.license_approved, authority_checked=args.authority_checked)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
