import XCTest
@testable import HuntCore
final class BackupEnvelopeTests:XCTestCase {
    func testStructureAndMerge()throws {
        let entry=BackupEnvelope.Entry(name:"field.json",bytes:Data([1]),sha256:String(repeating:"a",count:64))
        let envelope=BackupEnvelope(files:[entry])
        XCTAssertNoThrow(try envelope.validateStructure(required:["field.json"]))
        XCTAssertThrowsError(try envelope.validateStructure(required:["observations.json"]))
        XCTAssertThrowsError(try BackupEnvelope(files:[entry,entry]).validateStructure(required:["field.json"]))
        XCTAssertEqual(BackupMerge.records([1,2],[2,3],id:{$0}),[1,2,3])
    }
}
