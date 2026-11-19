import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from build_from_pbf import parse_bbox, tile_count, build_pbf

class PBFTests(unittest.TestCase):
    def test_bbox(self):
        self.assertEqual(parse_bbox('76.9,43.2,77,43.3'), (76.9,43.2,77.0,43.3))
        for raw in ('76,43,77', '76,43,75,44', '76,43,77,44', 'nan,43,77,44'):
            with self.assertRaises(ValueError): parse_bbox(raw)

    def test_tile_budget(self):
        bbox = parse_bbox('76.9,43.2,77,43.3')
        self.assertGreater(tile_count(bbox, 9, 14), 0)
        with self.assertRaises(ValueError): tile_count(bbox, 18, 19)

    def test_missing_pbf(self):
        with self.assertRaises(ValueError):
            build_pbf('missing.osm.pbf', 'out.mbtiles', parse_bbox('76.9,43.2,77,43.3'), 9, 10)

    def test_budget_rejects_before_running(self):
        with tempfile.TemporaryDirectory() as d:
            pbf = Path(d)/'region.osm.pbf'; pbf.write_bytes(b'dummy')
            with self.assertRaises(ValueError):
                build_pbf(pbf, Path(d)/'out.mbtiles', parse_bbox('76.9,43.2,77,43.3'), 9, 14, max_tiles=1)

    def test_missing_osmium(self):
        with tempfile.TemporaryDirectory() as d:
            pbf = Path(d)/'region.osm.pbf'; pbf.write_bytes(b'dummy')
            with patch('build_from_pbf.shutil.which', return_value=None):
                with self.assertRaisesRegex(ValueError, 'osmium'):
                    build_pbf(pbf, Path(d)/'out.mbtiles', parse_bbox('76.9,43.2,77,43.3'), 9, 10)

if __name__ == '__main__': unittest.main()
