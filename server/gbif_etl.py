"""Conservative GBIF occurrence -> *unpublished* ground wildlife proposal.

Only verified external boundary metadata is accepted. Raw coordinates never leave
this ingestion module. A human must review the resulting pack before publishing.
"""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import json
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from shapely.geometry import Point, shape
from shapely.validation import explain_validity

from server.wildlife import validate

GBIF_ENDPOINT = 'https://api.gbif.org/v1/occurrence/search'
# Exclude noncommercial records from potential commercial/public redistribution.
LICENSES = {'CC0_1_0', 'CC_BY_4_0'}
LICENSE_URLS = {
    'https://creativecommons.org/publicdomain/zero/1.0/': 'CC0_1_0',
    'http://creativecommons.org/publicdomain/zero/1.0/': 'CC0_1_0',
    'https://creativecommons.org/licenses/by/4.0/': 'CC_BY_4_0',
    'http://creativecommons.org/licenses/by/4.0/': 'CC_BY_4_0',
}
DISALLOWED_ISSUES = {'ZERO_COORDINATE', 'COORDINATE_OUT_OF_RANGE', 'COUNTRY_COORDINATE_MISMATCH',
                     'GEODETIC_DATUM_INVALID', 'COORDINATE_INVALID', 'COORDINATE_REPROJECTION_FAILED'}


def load_verified_boundary(path: Path):
    raw = json.loads(path.read_text(encoding='utf-8'))
    if raw.get('type') != 'Feature' or not isinstance(raw.get('properties'), dict):
        raise ValueError('expected GeoJSON Feature with official source metadata')
    p = raw['properties']
    if p.get('boundary_verified') is not True or not isinstance(p.get('ground_id'), str) or not p['ground_id']:
        raise ValueError('only manually verified hunting ground boundaries allowed')
    from server.wildlife import https, iso_date
    if not https(p.get('source_url')) or not iso_date(p.get('valid_at')) or not p.get('license'):
        raise ValueError('missing verified source URL, legal valid_at or license')
    geometry = shape(raw['geometry'])
    if geometry.geom_type not in ('Polygon', 'MultiPolygon') or geometry.is_empty or not geometry.is_valid:
        raise ValueError('invalid hunting ground polygon: '+explain_validity(geometry))
    if any(not (-180 <= x <= 180 and -90 <= y <= 90) for x, y in _coords(geometry)):
        raise ValueError('coordinates outside WGS84')
    return p['ground_id'], geometry, p


def _coords(geometry):
    if geometry.geom_type == 'Polygon':
        for ring in [geometry.exterior, *geometry.interiors]:
            yield from ring.coords
    else:
        for polygon in geometry.geoms:
            yield from _coords(polygon)


def fetch_live_page(offset: int, limit: int, geometry=None) -> dict:
    params = {'country': 'KZ', 'hasCoordinate': 'true', 'offset': offset, 'limit': limit}
    if geometry is not None:
        minx,miny,maxx,maxy = geometry.bounds
        if maxx-minx >= 180 or maxy-miny >= 90:
            raise ValueError('ground bounds too large for GBIF scoped search')
        # GBIF geometry search supports WKT; rectangle is a superset of the
        # ground and we perform strict point-in-polygon locally afterward.
        params['geometry'] = (f'POLYGON(({minx} {miny},{maxx} {miny},'
                              f'{maxx} {maxy},{minx} {maxy},{minx} {miny}))')
    query = urlencode(params)
    req = Request(GBIF_ENDPOINT+'?'+query, headers={'User-Agent': 'HuntMapKZ-ETL/0.7 (conservative; human review)', 'Accept': 'application/json'})
    with urlopen(req, timeout=30) as response:
        if response.status != 200: raise ValueError('GBIF HTTP error')
        # API response bounded; reject oversized pages.
        raw = response.read(5_000_001)
    if len(raw) > 5_000_000: raise ValueError('oversized GBIF response')
    return json.loads(raw)


def ingest(fetch_page, geometry, ground_id: str, generated_at: str, *, page_size=100, max_records=1000,
           max_uncertainty_m=1000, boundary_buffer_m=1000):
    """Fetch entire bounded search result or fail closed; never silently publish a partial scan.

    The inclusion test uses conservative buffer in degrees, overestimating uncertainty
    near Kazakhstan latitudes. This is a screening heuristic, not geodesic proof.
    """
    if page_size < 1 or page_size > 300 or max_records < 1 or max_records > 100_000:
        raise ValueError('unsafe API pagination settings')
    if max_uncertainty_m <= 0 or boundary_buffer_m < 0: raise ValueError('invalid uncertainty')
    from server.wildlife import iso_date
    if not iso_date(generated_at): raise ValueError('invalid generation timestamp')
    if not isinstance(ground_id, str) or not ground_id: raise ValueError('invalid ground')
    issues = Counter()
    entries = defaultdict(list)
    visited = set()
    offset = 0
    total = None
    while True:
        if offset >= max_records: raise ValueError('GBIF source exceeds max_records; use a scoped/filtered source')
        page = fetch_page(offset, min(page_size, max_records-offset))
        if not isinstance(page, dict) or not isinstance(page.get('results'), list) or type(page.get('count')) is not int:
            raise ValueError('invalid GBIF response')
        if page['count'] < 0 or (total is not None and total != page['count']):
            raise ValueError('GBIF count changed during retrieval; retry snapshot')
        total = page['count']
        if total > max_records: raise ValueError('GBIF search too large; refusing partial catalog')
        rows = page['results']
        if len(rows) > min(page_size, max_records-offset) or offset+len(rows) > total:
            raise ValueError('GBIF page exceeds requested range')
        if not rows and offset < total: raise ValueError('incomplete GBIF response')
        for rec in rows:
            if not isinstance(rec, dict):
                issues['malformed'] += 1; continue
            key = rec.get('key')
            if type(key) is not int or key < 0 or key in visited:
                issues['duplicate_or_missing_id'] += 1; continue
            visited.add(key)
            license_id = LICENSE_URLS.get(rec.get('license'), rec.get('license'))
            if license_id not in LICENSES:
                issues['license'] += 1; continue
            if rec.get('issues') and DISALLOWED_ISSUES.intersection(rec['issues']):
                issues['location_issues'] += 1; continue
            if rec.get('informationWithheld') or rec.get('dataGeneralizations') or rec.get('coordinatePrecision'):
                issues['obscured'] += 1; continue
            if rec.get('taxonRank') not in ('SPECIES', 'SUBSPECIES'):
                issues['rank'] += 1; continue
            name, taxon_key = rec.get('scientificName'), rec.get('taxonKey')
            if not isinstance(name, str) or not name.strip() or len(name) > 200 or type(taxon_key) is not int or taxon_key < 1:
                issues['taxonomy'] += 1; continue
            lat, lon, unc = rec.get('decimalLatitude'), rec.get('decimalLongitude'), rec.get('coordinateUncertaintyInMeters')
            if type(lat) not in (int,float) or type(lon) not in (int,float) or type(unc) not in (int,float):
                issues['uncertainty_missing'] += 1; continue
            if not (-90 <= lat <= 90 and -180 <= lon <= 180) or not (0 < unc <= max_uncertainty_m):
                issues['uncertainty_invalid'] += 1; continue
            point = Point(lon, lat)
            if not geometry.contains(point):
                issues['outside_ground'] += 1; continue
            # buffer degrees are intentionally generous: 1 degree longitude can be <111km.
            # For KZ latitudes this can still underestimate; 1 / 50km approx is conservative.
            if geometry.boundary.distance(point) * 50_000 <= unc + boundary_buffer_m:
                issues['near_boundary'] += 1; continue
            if rec.get('sensitive') is True or rec.get('geospatialIssue') is True:
                issues['sensitive'] += 1; continue
            event = rec.get('eventDate')
            if not isinstance(event,str) or len(event) < 10:
                issues['date_missing'] += 1; continue
            try: date = datetime.fromisoformat(event[:10]).date()
            except ValueError:
                issues['date_invalid'] += 1; continue
            entries[taxon_key].append((key, name.strip(), date, license_id))
        offset += len(rows)
        if offset >= total: break
    # An inference of residency is NOT licensed by sparse point observations.
    taxa = []
    for key, observations in sorted(entries.items()):
        dates = [a[2] for a in observations]
        most_recent = max(dates)
        # No location is stored, returned or logged.
        taxa.append({'id':f'GBIF-{key}', 'scientific_name':observations[0][1],
            'category':'probable' if len(observations) >= 2 else 'historical',
            'evidence_count':len(observations),
            'latest_evidence_at':most_recent.isoformat()+'T00:00:00Z',
            'source_record_url':f'https://www.gbif.org/occurrence/{observations[0][0]}'})
    # Mixed CC0 + CC BY is conservatively labelled CC BY.
    all_licenses = {o[3] for group in entries.values() for o in group}
    license_description = 'CC BY 4.0 (source record attribution required)' if 'CC_BY_4_0' in all_licenses else 'CC0 1.0'
    pack = {'schema_version':1, 'source':'GBIF (candidate; manual review required)',
            'source_url':'https://www.gbif.org/', 'license':license_description,
            'generated_at':generated_at, 'ground_id':ground_id, 'taxa':taxa}
    encoded = json.dumps(pack, ensure_ascii=False, sort_keys=True, separators=(',',':')).encode('utf-8')
    validate(encoded)
    return encoded, {'scanned':len(visited), 'accepted_observations':sum(map(len,entries.values())),
                     'taxa':len(taxa), 'rejected':dict(sorted(issues.items())),
                     'review_required':True, 'published':False,
                     'boundary_screening':'conservative degree approximation; not geodesic certified',
                     'attribution_warning':'Taxon card only links one occurrence; review source datasets and license obligations before publication'}


def main():
    p = argparse.ArgumentParser(description='GBIF -> proposed wildlife catalog; never auto-publish')
    p.add_argument('--boundary', required=True, type=Path)
    p.add_argument('--fixture', type=Path, help='offline GBIF page fixture (for tests/demo)')
    p.add_argument('--output', required=True, type=Path)
    p.add_argument('--max-records', type=int, default=1000)
    args = p.parse_args()
    ground_id, geom, props = load_verified_boundary(args.boundary)
    if args.fixture:
        fixture = json.loads(args.fixture.read_text(encoding='utf-8'))
        if not isinstance(fixture, dict) or not isinstance(fixture.get('results'), list): raise ValueError('bad fixture')
        def fetch(offset,limit):
            return {'count':len(fixture['results']), 'results':fixture['results'][offset:offset+limit]}
    else: fetch=lambda offset, limit: fetch_live_page(offset, limit, geom)
    timestamp = datetime.now(timezone.utc).isoformat(timespec='seconds').replace('+00:00','Z')
    data, report = ingest(fetch,geom,ground_id,timestamp,max_records=args.max_records)
    if args.output.exists(): raise ValueError('refusing to overwrite output')
    args.output.parent.mkdir(parents=True,exist_ok=True)
    args.output.write_bytes(data)
    args.output.with_suffix('.review.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(report,ensure_ascii=False,indent=2))
    print('NOT PUBLISHED: human evidence, licensing, legal and boundary review required')


if __name__ == '__main__': main()
