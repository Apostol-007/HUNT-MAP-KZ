"""Static iOS regression contracts for bundled PDF laws and diagnostic export."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
IOS = ROOT / "iOS" / "HuntMap"
DOCUMENTS = {
    "wildlife-protection.pdf": 94,
    "rules-civil-service-weapons.pdf": 115,
    "approval-voucher-form-rules.pdf": 8,
    "approval-hunting-rules.pdf": 20,
}


def test_original_legal_pdfs_are_bundled_and_searchable():
    reader = (IOS / "LegalLibraryView.swift").read_text()
    assert "import PDFKit" in reader
    assert "PDFDocument(url: url)" in reader
    assert "findString(" in reader
    assert "PDFKitPageView" in reader
    assert "Библиотека охотника" in reader
    for name in DOCUMENTS:
        file = IOS / "LegalDocuments" / name
        assert file.is_file(), f"Missing source: {name}"
        assert file.read_bytes().startswith(b"%PDF-"), name
        assert file.stat().st_size > 60_000, name


def test_legal_library_is_opened_from_home():
    main = (IOS / "MainView.swift").read_text()
    assert 'showLegalLibrary = true' in main
    assert '.sheet(isPresented: $showLegalLibrary)' in main
    assert 'legal_library_home' in main


def test_diagnostic_events_record_cause_and_action():
    log = (IOS / "AppDiagnosticLog.swift").read_text()
    diag = (IOS / "Diagnostics.swift").read_text()
    weather = (IOS / "WeatherGridService.swift").read_text()
    assert "rootCause" in log and "nextAction" in log
    assert 'case 429:' in log and 'case 400:' in log
    assert "recordHTTP" in weather
    assert "recordError" in weather
    assert 'diagnostics.export()' in diag
    assert 'Скопировать полный отчёт' in diag
    assert "GPS coordinates: REDACTED" in diag
