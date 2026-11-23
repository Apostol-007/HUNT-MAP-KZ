"""Checks the actual Protomaps grid preparation contract without network calls."""
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tools" / "prepare_protomaps_grid.py"
SPEC = importlib.util.spec_from_file_location("hunt_protomaps_grid", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

def test_kazakhstan_grid_is_valid_and_bounded():
    bounds = MODULE.parse_bbox("76.7,43.1,77.2,43.5")
    grid = list(MODULE.cells(bounds, 0.1, 100))
    assert grid
    assert len(grid) <= 100
    for key, box in grid:
        assert key.startswith("kz_")
        assert len(box) == 4
        assert box[0] < box[2] and box[1] < box[3]

def test_refuse_huge_regions():
    import pytest
    with pytest.raises(ValueError):
        list(MODULE.cells([60, 40, 90, 55], 0.1, 100))

def test_catalog_is_empty_until_pmtiles_files_exist():
    path = ROOT / "hosting_upload" / "protomaps" / "catalog.json"
    catalog = json.loads(path.read_text(encoding="utf-8"))
    assert catalog["schema"] == "hunt-protomaps-v1"
    assert isinstance(catalog["packs"], list)
    for pack in catalog["packs"]:
        assert pack["url"].startswith("https://")
        assert pack["sha256"] and pack["bytes"] > 127

def test_publisher_uses_real_region_extraction():
    code = SCRIPT.read_text(encoding="utf-8")
    assert 'subprocess.run(command, check=True, timeout=1800,' in code
    assert 'pmtiles, "extract"' in code
    assert '"verify"' in code
    assert 'hashlib.sha256()' in code

def test_source_discovery_without_html_build_rows():
    import datetime
    names = MODULE.source_candidates("<html><script src='app.js'></script></html>",
                                     datetime.date(2026, 11, 23))
    assert "https://build.protomaps.com/20261116.pmtiles" in names
    assert names[0].endswith("20261123.pmtiles")

def test_source_discovery_from_official_dates():
    import datetime
    names = MODULE.source_candidates("published: 20261115.pmtiles and 20261116.pmtiles",
                                     datetime.date(2026, 11, 23))
    assert names.index("https://build.protomaps.com/20261116.pmtiles") < names.index(
        "https://build.protomaps.com/20261115.pmtiles")

def test_remote_probe_reads_only_eight_header_bytes():
    class Response:
        status = 206
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def read(self, n):
            assert n == 8
            return b"PMTiles" + bytes([3])
    def opener(req, timeout):
        assert req.get_header("Range") == "bytes=0-7"
        return Response()
    assert MODULE.probe_source("https://build.protomaps.com/20261116.pmtiles", opener)


def test_country_grid_is_partitioned_into_batches_of_100():
    region = MODULE.parse_bbox("46.49,40.56,87.31,55.44")
    groups = MODULE.partition(MODULE.cells(region, 0.5, 100000), 100)
    first = next(groups)
    second = next(groups)
    assert len(first) == len(second) == 100
    assert first[-1][0] != second[0][0]


def test_catalog_is_written_incrementally_and_restored(tmp_path):
    catalog = tmp_path / "catalog.json"
    entry = {"id": "cell_a", "bounds": [76.0, 43.0, 76.5, 43.5],
             "bytes": 300, "maxzoom": 15,
             "url": "https://create.web-works.kz/maps/protomaps/cell_a.pmtiles",
             "sha256": "a" * 64}
    MODULE.atomic_catalog(catalog, {"cell_a": entry}, "local.pmtiles", "https://create.web-works.kz/maps/protomaps")
    restored = MODULE.load_catalog(catalog)
    assert restored["cell_a"] == entry
    assert not (tmp_path / "catalog.json.tmp").exists()


def test_partial_archive_is_not_used_as_completed(tmp_path):
    destination = tmp_path / "cell_a.pmtiles"
    destination.write_bytes(b"bad")
    entry = {"bounds": [76.0, 43.0, 76.5, 43.5],
             "bytes": 3, "maxzoom": 15,
             "url": "https://create.web-works.kz/maps/protomaps/cell_a.pmtiles",
             "sha256": "a" * 64}
    assert not MODULE.cached_record(entry, destination, entry["bounds"], "https://create.web-works.kz/maps/protomaps", 15)


def test_windows_batch_has_no_region_prompt_and_never_autocloses():
    batch = (ROOT / "tools" / "PREPARE_PROTOMAPS_WINDOWS.bat").read_text(encoding="utf-8")
    assert "--batch-size 100" in batch
    assert "46.49,40.56,87.31,55.44" in batch
    assert "pause" in batch.lower()
    assert "set /p REGION" not in batch


def test_stale_different_grid_is_replaced_not_reindexed():
    code = SCRIPT.read_text(encoding="utf-8")
    assert 'previous.get("bounds") == bbox' in code
    assert 'previous.get("maxzoom") == args.maxzoom' in code
    assert 'Replace stale/different-grid file' in code


def test_pmtiles_output_is_saved_in_progress_log():
    code = SCRIPT.read_text(encoding="utf-8")
    assert 'stdout=subprocess.PIPE' in code
    assert 'stderr=subprocess.STDOUT' in code
    assert 'prepare_protomaps.log' in code
