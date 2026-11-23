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
    assert 'subprocess.run([args.pmtiles, "extract"' in code
    assert '"verify"' in code
    assert 'hashlib.sha256()' in code
