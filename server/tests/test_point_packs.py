import hashlib
import json
import sqlite3
from fastapi.testclient import TestClient
from server import app as api


def _write_pack(path, pack_id, bounds):
    dbpath = path / (pack_id + '.bin')
    with sqlite3.connect(dbpath) as db:
        db.execute('CREATE TABLE metadata (name TEXT, value TEXT)')
        db.execute('INSERT INTO metadata VALUES (?,?)', ('bounds', bounds))
    data = dbpath.read_bytes()
    return {'pack_id': pack_id, 'scope': 'region', 'scope_id': 'test',
            'size_bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest(),
            'source_version':'test', 'license':'test', 'verified':False,
            'layers':['raster-mbtiles']}


def test_point_catalog_uses_mbtiles_bounds(tmp_path, monkeypatch):
    monkeypatch.setattr(api, 'PACKS', tmp_path)
    record = _write_pack(tmp_path, 'almaty', '76.0,42.0,78.0,44.0')
    (tmp_path / 'catalog.json').write_text(json.dumps([record]))
    client = TestClient(api.app)
    response = client.get('/v1/packs/at-point', params={'lat': 43.25, 'lon': 76.9})
    assert response.status_code == 200, response.text
    assert [p['pack_id'] for p in response.json()] == ['almaty']
    assert client.get('/v1/packs/at-point', params={'lat': 49, 'lon': 76.9}).json() == []


def test_bad_bounds_and_invalid_coordinates(tmp_path, monkeypatch):
    monkeypatch.setattr(api, 'PACKS', tmp_path)
    record = _write_pack(tmp_path, 'bad', 'missing,coordinate,data')
    (tmp_path / 'catalog.json').write_text(json.dumps([record]))
    client = TestClient(api.app)
    assert client.get('/v1/packs/at-point', params={'lat': 43.25, 'lon':76.9}).json() == []
    assert client.get('/v1/packs/at-point', params={'lat': 100, 'lon':76.9}).status_code == 422
    assert client.get('/v1/packs/at-point', params={'lat': 43, 'lon':181}).status_code == 422


def test_antimeridian_bounds(tmp_path, monkeypatch):
    monkeypatch.setattr(api, 'PACKS', tmp_path)
    record = _write_pack(tmp_path, 'dateline', '170,-10,-170,10')
    (tmp_path / 'catalog.json').write_text(json.dumps([record]))
    client = TestClient(api.app)
    assert len(client.get('/v1/packs/at-point', params={'lat':0,'lon':179}).json()) == 1
    assert len(client.get('/v1/packs/at-point', params={'lat':0,'lon':-179}).json()) == 1
    assert client.get('/v1/packs/at-point', params={'lat':0,'lon':0}).json() == []
