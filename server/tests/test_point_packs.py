import hashlib
import sqlite3
from fastapi.testclient import TestClient
from server import app as api


def test_point_catalog_uses_mbtiles_bounds(tmp_path, monkeypatch):
    monkeypatch.setattr(api, 'PACKS', tmp_path)
    dbpath = tmp_path / 'almaty.bin'
    with sqlite3.connect(dbpath) as db:
        db.execute('CREATE TABLE metadata (name TEXT, value TEXT)')
        db.execute("INSERT INTO metadata VALUES ('bounds','76.0,42.0,78.0,44.0')")
    data = dbpath.read_bytes()
    import json
    (tmp_path / 'catalog.json').write_text(json.dumps([{
        'pack_id':'almaty','scope':'region','scope_id':'test',
        'size_bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),
        'source_version':'test','license':'test','verified':False,'layers':['raster-mbtiles']
    }]))
    client = TestClient(api.app)
    assert [p['pack_id'] for p in client.get('/v1/packs/at-point',params={'lat':43.25,'lon':76.9}).json()] == ['almaty']
    assert client.get('/v1/packs/at-point',params={'lat':50,'lon':76.9}).json() == []
    assert client.get('/v1/packs/at-point',params={'lat':100,'lon':76.9}).status_code == 422
