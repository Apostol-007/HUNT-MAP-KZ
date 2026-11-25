import XCTest
@testable import HuntCore
final class ObservationTests:XCTestCase {
    func testValidationAndPrivateExport() throws {
        let item=WildlifeObservation(species:"Test species",point:GeoPoint(43,76),accuracyMeters:5,groundID:"x",groundName:"test",photoJPEG:Data([1,2]))
        XCTAssertTrue(item.valid)
        XCTAssertTrue(ObservationValidation.matches(item,query:"species"))
        XCTAssertFalse(WildlifeObservation(species:" ").valid)
        let data=try ObservationValidation.export([item],includeLocations:false,includePhotos:false)
        let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
        let result=try XCTUnwrap(decoder.decode([WildlifeObservation].self,from:data).first)
        XCTAssertNil(result.point);XCTAssertNil(result.groundID);XCTAssertNil(result.photoJPEG)
        XCTAssertEqual(result.id,item.id)
    }
}
