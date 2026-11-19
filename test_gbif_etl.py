import json
from datetime import datetime, timezone
import pytest
from shapely.geometry import Polygon
from server.gbif_etl import ingest, load_verified_boundary, LICENSE_URLS
from server.wildlife import validate

POLY = Polygon([(70,40),(72,40),(72,42),(70,42)])
DATE='2026-11-19T07:00:00Z'

def observation(key=101, **kw):
    r={'key':key, 'license':'CC0_1_0', 'taxonRank':'SPECIES', 'taxonKey':777,
       'scientificName':'Testus exampleus', 'decimalLatitude':41.0,
       'decimalLongitude':71.0, 'coordinateUncertaintyInMeters':30,
       'eventDate':'2025-07-01T00:00:00', 'issues':[]}
    r.update(kw)
    return r

def fetch(items):
    return lambda offset, limit: {'count':len(items),'results':items[offset:offset+limit]}

def parse(items, **kwargs):
    raw, report=ingest(fetch(items),POLY,'DEMO',DATE,page_size=2,**kwargs)
    return validate(raw), report, raw

def test_deduplicate_and_aggregate_without_coordinates():
    doc, report, raw=parse([observation(1),observation(1),observation(2,license='CC_BY_4_0')])
    assert report['scanned']==2 and report['accepted_observations']==2
    assert report['rejected']['duplicate_or_missing_id']==1
    assert doc['taxa'][0]['category']=='probable' and doc['taxa'][0]['evidence_count']==2
    assert 'latitude' not in raw.decode() and '41.0' not in raw.decode()
    assert doc['license'].startswith('CC BY')
    assert not report['published'] and report['review_required']

def test_reject_unlicensed_obscured_missing_uncertainty_edge_and_bad_issues():
    items=[observation(1,license='CC_BY_NC_4_0'),observation(2,informationWithheld='private'),
           observation(3,coordinateUncertaintyInMeters=None),observation(4,decimalLatitude=40.0001),
           observation(5,issues=['COUNTRY_COORDINATE_MISMATCH']),
           observation(6,decimalLongitude=82), observation(7),
           observation(8,coordinateUncertaintyInMeters=100_000),
           observation(9,sensitive=True)]
    doc, report, _=parse(items)
    assert len(doc['taxa'])==1 and doc['taxa'][0]['evidence_count']==1
    assert doc['taxa'][0]['category']=='historical'
    assert report['accepted_observations']==1 and sum(report['rejected'].values())==8

def test_partial_results_fail_closed():
    with pytest.raises(ValueError,match='too large'):
        parse([observation(i) for i in range(5)],max_records=4)
    with pytest.raises(ValueError,match='incomplete'):
        ingest(lambda o,l:{'count':3,'results':[]},POLY,'DEMO',DATE)
    with pytest.raises(ValueError,match='count changed'):
        def changing(o,l):return {'count':4 if o==0 else 5,'results':[observation(i) for i in range(o,o+l)]}
        ingest(changing,POLY,'DEMO',DATE,page_size=2)

def test_verified_boundary_rejects_demo_and_invalid(tmp_path):
    d={'type':'Feature','properties':{'ground_id':'D','boundary_verified':False,'source_url':'https://example.org/boundary',
       'valid_at':DATE,'license':'EXAMPLE'},'geometry':{'type':'Polygon','coordinates':[[[70,40],[72,40],[72,42],[70,42],[70,40]]]}}
    path=tmp_path/'boundary.json';path.write_text(json.dumps(d))
    with pytest.raises(ValueError,match='verified'):load_verified_boundary(path)
    d['properties']['boundary_verified']=True
    path.write_text(json.dumps(d))
    id, g, meta=load_verified_boundary(path)
    assert id=='D' and g.area==4
    d['geometry']['coordinates']=[[[70,40],[72,42],[72,40],[70,42],[70,40]]]
    path.write_text(json.dumps(d))
    with pytest.raises(ValueError,match='invalid hunting ground'):load_verified_boundary(path)

def test_empty_input_never_claims_no_species():
    doc, report, _=parse([])
    assert doc['taxa']==[] and report['review_required'] and report['accepted_observations']==0

def test_gbif_wkt_search_is_scoped(monkeypatch):
    from server import gbif_etl
    from urllib.parse import urlsplit, parse_qs
    seen=[]
    class Result:
        status=200
        def __enter__(self):return self
        def __exit__(self,*args):pass
        def read(self, n):return b'{"count":0,"results":[]}'
    def opener(req, timeout):
        seen.append(parse_qs(urlsplit(req.full_url).query));return Result()
    monkeypatch.setattr(gbif_etl,'urlopen',opener)
    gbif_etl.fetch_live_page(0, 100, POLY)
    assert seen[0]['country']==['KZ']
    assert seen[0]['geometry'][0].startswith('POLYGON((70.0 40.0')


def test_excess_records_in_single_page_rejected():
    with pytest.raises(ValueError,match='exceeds requested range'):
        ingest(lambda o,l:{'count':1,'results':[observation(1),observation(2)]},POLY,'D',DATE,page_size=1)
