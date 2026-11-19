import XCTest
@testable import HuntCore

final class WildlifeTests: XCTestCase {
    private func specimen() -> [String: Any] {
        ["schema_version": 1, "source": "Test science registry", "source_url": "https://example.org/data", "license": "CC BY 4.0", "generated_at": "2026-11-19T06:00:00Z", "ground_id": "TEST-ONLY", "taxa": [["id":"test-1", "scientific_name":"Testus exemplar", "name_ru":"Тестовый вид", "category":"confirmed", "evidence_count":2, "latest_evidence_at":"2026-10-10T12:00:00Z"]]]
    }
    private func decode(_ json: [String: Any]) throws -> WildlifePack {
        try WildlifeValidator.decode(JSONSerialization.data(withJSONObject: json))
    }
    func testValidPack() throws { XCTAssertEqual(try decode(specimen()).taxa.count, 1) }
    func testPreciseCoordinatesRejected() throws {
        var obj=specimen(); var taxa=obj["taxa"] as! [[String:Any]];taxa[0]["latitude"]=43.22;obj["taxa"]=taxa
        XCTAssertThrowsError(try decode(obj)) { XCTAssertEqual($0 as? WildlifeValidationError,.forbiddenLocation) }
    }
    func testDuplicateRejected() throws {
        var obj=specimen(); let taxa=obj["taxa"] as! [[String:Any]]; obj["taxa"]=taxa+taxa
        XCTAssertThrowsError(try decode(obj)) { XCTAssertEqual($0 as? WildlifeValidationError,.duplicateTaxon) }
    }
    func testUnverifiedURLRejected() throws {
        var obj=specimen();obj["source_url"]="http://example.org"
        XCTAssertThrowsError(try decode(obj)) { XCTAssertEqual($0 as? WildlifeValidationError,.invalidMetadata) }
    }
    func testUnsupportedVersion() throws {
        var obj=specimen(); obj["schema_version"]=2
        XCTAssertThrowsError(try decode(obj)) { XCTAssertEqual($0 as? WildlifeValidationError,.invalidMetadata) }
    }
    func testUnsubstantiatedConfirmedRejected() throws {
        var obj=specimen(); var taxa=obj["taxa"] as! [[String:Any]];taxa[0]["evidence_count"]=0;obj["taxa"]=taxa
        XCTAssertThrowsError(try decode(obj)) { XCTAssertEqual($0 as? WildlifeValidationError,.invalidTaxon) }
    }
}
