import unittest
from fetch_osm_region import validate_bbox, query_for, to_geojson

class FetchOSMTests(unittest.TestCase):
    def test_bbox_limits(self):
        validate_bbox((76.90,43.20,77.00,43.30))
        with self.assertRaises(ValueError): validate_bbox((70,40,80,50))
        with self.assertRaises(ValueError): validate_bbox((77,43,76,44))
    def test_query(self):
        query = query_for((76.9,43.2,77.0,43.3))
        self.assertIn('way["highway"]',query)
        self.assertIn('out geom',query)
    def test_transform(self):
        data={'elements':[{'type':'way','id':12,'tags':{'highway':'track'},'geometry':[{'lon':76.9,'lat':43.2},{'lon':76.91,'lat':43.21}]}, {'type':'node','id':9}, {'type':'way','id':12,'tags':{'highway':'track'},'geometry':[{'lon':76.9,'lat':43.2},{'lon':76.91,'lat':43.21}]}]}
        result=to_geojson(data)
        self.assertEqual(len(result['features']),1)
        self.assertEqual(result['features'][0]['properties']['highway'],'track')
    def test_invalid_geometry(self):
        self.assertFalse(to_geojson({'elements':[{'type':'way','id':1,'tags':{'highway':'path'},'geometry':[{'lon':'nan','lat':43},{'lon':77,'lat':43}]}]})['features'])

if __name__ == '__main__': unittest.main()
