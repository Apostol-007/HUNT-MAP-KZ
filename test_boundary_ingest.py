import copy
import hashlib
import json
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from server import app as app_module
from server.boundary_ingest import stage, publish, validate_collection


def sample():
    return {'type': 'FeatureCollection', 'features': [{
        'type': 'Feature', 'properties': {
            'ground_id': 'TEST-AREA', 'name': 'Синтетический участок',
            'kind': 'huntingGround', 'source_url': 'https://example.org/demo',
            'valid_at': '2024-01-01', 'license': 'TEST ONLY',
            'boundary_verified': True,
        },
        'geometry': {'type': 'Polygon', 'coordinates': [[
            [76, 43], [77, 43], [77, 44], [76, 44], [76, 43]]]},
    }]}


def test_stage_never_trusts_claimed_verified(tmp_path):
    file = tmp_path / 'raw.json'
    file.write_text(json.dumps(sample()), encoding='utf-8')
    result = stage(file, tmp_path / 'staging')
    data = json.loads(Path(result['file']).read_text('utf-8'))
    assert result['status'] == 'STAGED_NOT_LEGALLY_VERIFIED'
    assert data['features'][0]['properties']['boundary_verified'] is False


def test_invalid_self_intersection_rejected():
    obj = sample()
    obj['features'][0]['geometry']['coordinates'] = [[
        [76, 43], [77, 44], [77, 43], [76, 44], [76, 43]]]
    with pytest.raises(ValueError, match='invalid polygon'):
        validate_collection(obj)


def test_invalid_coordinates_rejected():
    obj = sample()
    obj['features'][0]['geometry']['coordinates'][0][2] = [200, 44]
    with pytest.raises(ValueError, match='outside WGS84'):
        validate_collection(obj)


def test_duplicate_ids_rejected():
    obj = sample()
    obj['features'].append(copy.deepcopy(obj['features'][0]))
    with pytest.raises(ValueError, match='duplicate'):
        validate_collection(obj)


def test_missing_provenance_rejected():
    obj = sample()
    obj['features'][0]['properties']['source_url'] = 'http://example.org'
    with pytest.raises(ValueError, match='HTTPS'):
        validate_collection(obj)


def test_approval_required_and_hash_integrity(tmp_path):
    file = tmp_path / 'raw.json'
    file.write_text(json.dumps(sample()), encoding='utf-8')
    result = stage(file, tmp_path / 'staging')
    with pytest.raises(ValueError, match='explicit legal'):
        publish(result['candidate_sha256'], tmp_path / 'staging', tmp_path / 'published',
                approved_by='operator', license_approved=False, authority_checked=True)
    Path(result['file']).write_text('{}', encoding='utf-8')
    with pytest.raises(ValueError, match='modified'):
        publish(result['candidate_sha256'], tmp_path / 'staging', tmp_path / 'published',
                approved_by='operator', license_approved=True, authority_checked=True)


def test_publish_and_api(tmp_path, monkeypatch):
    file = tmp_path / 'raw.json'
    file.write_text(json.dumps(sample()), encoding='utf-8')
    staged = stage(file, tmp_path / 'staging')
    published = tmp_path / 'published'
    result = publish(staged['candidate_sha256'], tmp_path / 'staging', published,
                     approved_by='operator', license_approved=True, authority_checked=True)
    assert result['published'] == 1
    monkeypatch.setattr(app_module, 'BOUNDARIES', published)
    client = TestClient(app_module.app)
    listing = client.get('/v1/catalog/grounds')
    assert listing.status_code == 200
    assert len(listing.json()) == 1
    assert listing.json()[0]['boundary_verified'] is False
    response = client.get('/v1/grounds/TEST-AREA/geojson')
    assert response.status_code == 200
    assert hashlib.sha256(response.content).hexdigest() == listing.json()[0]['sha256']
    assert client.get('/v1/grounds/TEST-AREA/geojson', headers={'If-None-Match': response.headers['etag']}).status_code == 304
    assert client.get('/v1/grounds/UNKNOWN/geojson').status_code == 404
    # Corruption must fail closed.
    (published / (listing.json()[0]['sha256'] + '.geojson')).write_bytes(b'{}')
    assert client.get('/v1/grounds/TEST-AREA/geojson').status_code == 503
