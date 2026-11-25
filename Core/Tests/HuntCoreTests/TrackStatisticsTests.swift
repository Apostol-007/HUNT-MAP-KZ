import XCTest
@testable import HuntCore
final class TrackStatisticsTests:XCTestCase {
    func testGapIsNotDistance() {
        let now=Date()
        func sample(_ lat:Double,_ t:Double,_ split:Bool,_ h:Double)->TrackSample {
            TrackSample(point:GeoPoint(lat,76),time:now.addingTimeInterval(t),accuracy:5,altitude:h,speed:1,segmentStart:split)
        }
        let result=TrackStatistics.calculate([sample(43,0,true,100),sample(43.0001,10,false,110),sample(44,100,true,200),sample(44.0001,110,false,190)])
        XCTAssertEqual(result.distance,22.24,accuracy:1)
        XCTAssertEqual(result.gapSeconds,90)
        XCTAssertEqual(result.movingSeconds,20)
        XCTAssertEqual(result.ascent ?? -1,10)
        XCTAssertEqual(result.descent ?? -1,10)
    }
    func testMissingAltitudeAndLongGap() {
        let now=Date()
        let a=TrackSample(point:GeoPoint(43,76),time:now,accuracy:5,altitude:nil,speed:nil,segmentStart:false)
        let b=TrackSample(point:GeoPoint(43.1,76),time:now.addingTimeInterval(121),accuracy:5,altitude:nil,speed:nil,segmentStart:false)
        let result=TrackStatistics.calculate([a,b])
        XCTAssertEqual(result.distance,0)
        XCTAssertEqual(result.gapSeconds,121)
        XCTAssertNil(result.ascent)
        XCTAssertNil(result.maximumSpeed)
    }
}
