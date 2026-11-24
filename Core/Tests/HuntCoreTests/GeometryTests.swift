import Foundation
import Testing
@testable import HuntCore

func square(_ x: Double = 77, _ y: Double = 43) -> GeoPolygon {
    GeoPolygon(rings:[[GeoPoint(y,x),GeoPoint(y,x+0.01),GeoPoint(y+0.01,x+0.01),GeoPoint(y+0.01,x)]])
}
@Test func polygonInsideOutsideAndEdge() {
    let p=square()
    #expect(p.contains(GeoPoint(43.005,77.005)))
    #expect(!p.contains(GeoPoint(44,78)))
    #expect(p.contains(GeoPoint(43,77.005)))
}
@Test func polygonHole() {
    let outer=square().rings[0]
    let hole=[GeoPoint(43.004,77.004),GeoPoint(43.004,77.006),GeoPoint(43.006,77.006),GeoPoint(43.006,77.004)]
    let p=GeoPolygon(rings:[outer,hole])
    #expect(!p.contains(GeoPoint(43.005,77.005)))
    #expect(p.contains(GeoPoint(43.002,77.002)))
}
@Test func antiMeridian() {
    let p=GeoPolygon(rings:[[GeoPoint(10,179.5),GeoPoint(10,-179.5),GeoPoint(11,-179.5),GeoPoint(11,179.5)]])
    #expect(p.contains(GeoPoint(10.5,179.9)))
    #expect(p.contains(GeoPoint(10.5,-179.9)))
    #expect(!p.contains(GeoPoint(10.5,175)))
}
@Test func distanceAndAccuracy() {
    #expect(abs(GeoMath.meters(GeoPoint(0,0),GeoPoint(0,1))-111195)<100)
    #expect(square().distanceToBoundaryMeters(GeoPoint(43.005,77.005))>300)
}
@Test func transitionNeedsThreeFixes() {
    let zone=GeoZone(id:"z",name:"Demo",kind:.huntingGround,verified:false,source:"test",polygons:[square()])
    let engine=BoundaryEngine()
    let t=Date()
    func fix(_ lat:Double)->GPSFix { GPSFix(position:GeoPoint(lat,77.005),accuracyMeters:5,timestamp:t) }
    #expect(engine.process(fix(43.005),zones:[zone],now:t).isEmpty)
    #expect(engine.process(fix(43.015),zones:[zone],now:t).filter{ if case .exited = $0 {return true};return false }.isEmpty)
    #expect(engine.process(fix(43.015),zones:[zone],now:t).filter{ if case .exited = $0 {return true};return false }.isEmpty)
    #expect(engine.process(fix(43.015),zones:[zone],now:t).contains(.exited(zoneID:"z")))
}
@Test func poorAccuracyNeverConfirmsCrossing() {
    let zone=GeoZone(id:"z",name:"Demo",kind:.huntingGround,verified:false,source:"test",polygons:[square()])
    let engine=BoundaryEngine(); let t=Date()
    _=engine.process(GPSFix(position:GeoPoint(43.005,77.005),accuracyMeters:5,timestamp:t),zones:[zone],now:t)
    for _ in 0..<5 {
        let result=engine.process(GPSFix(position:GeoPoint(43.015,77.005),accuracyMeters:100,timestamp:t),zones:[zone],now:t)
        #expect(!result.contains(.exited(zoneID:"z")))
    }
}
@Test func oneThousandReferenceGridPoints() {
    let p=square()
    for row in 0..<40 {
        for col in 0..<40 {
            let lat=42.99+Double(row)*0.001
            let lon=76.99+Double(col)*0.001
            let expected=(10...20).contains(row) && (10...20).contains(col)
            #expect(p.contains(GeoPoint(lat,lon)) == expected)
        }
    }
}
@Test func staleGPSFixRejected() {
    let zone=GeoZone(id:"z",name:"Demo",kind:.huntingGround,verified:false,source:"test",polygons:[square()])
    let engine=BoundaryEngine();let now=Date()
    let stale=GPSFix(position:GeoPoint(43.005,77.005),accuracyMeters:5,timestamp:now.addingTimeInterval(-60))
    #expect(engine.process(stale,zones:[zone],now:now).isEmpty)
}


import XCTest
final class GroundMetadataTests: XCTestCase {
    func testOriginalAttributesSurviveJSONRoundTrip() throws {
        let zone = GeoZone(id: "official-1", name: "Манул", kind: .huntingGround,
                           verified: false, source: "demo source", polygons: [],
                           attributes: ["Название": "Манул", "Площадь, га": "124767.23",
                                        "Договор на ведение охот. хоз.": "12.05.2006 № 17"])
        let output = try JSONDecoder().decode(GeoZone.self, from: JSONEncoder().encode(zone))
        XCTAssertEqual(output.attributes?["Площадь, га"], "124767.23")
        XCTAssertEqual(output.attributes?["Название"], "Манул")
        XCTAssertFalse(output.verified)
    }
    func testOldZoneWithoutAttributesStillDecodes() throws {
        let json = #"{"id":"legacy","name":"Old","kind":"huntingGround","verified":false,"source":"old","polygons":[]}"#
        let old = try JSONDecoder().decode(GeoZone.self, from: Data(json.utf8))
        XCTAssertNil(old.attributes)
    }
}

@Test func routePolylineDistanceUsesSegmentsNotOnlyVertices() {
    let road = [GeoPoint(43.0, 76.0), GeoPoint(43.0, 76.1)]
    let middle = GeoPoint(43.0001, 76.05)
    #expect(GeoMath.distanceToPolyline(middle, road) < 20)
    #expect(GeoMath.distanceToPolyline(middle, []) == .infinity)
    #expect(GeoMath.distanceToPolyline(road[0], [road[0]]) == 0)
}

@Test func boundaryQueuePreservesThreeConsecutiveFixes() {
    var queue = BoundaryFixQueue()
    let zone = GeoZone(id: "z", name: "Test", kind: .huntingGround, verified: false, source: "test", polygons: [square()])
    let engine = BoundaryEngine()
    let t = Date()
    let inside = GPSFix(position: GeoPoint(43.005, 77.005), accuracyMeters: 5, timestamp: t)
    _ = engine.process(inside, zones: [zone], now: t)
    for index in 1...3 {
        let fix = GPSFix(position: GeoPoint(43.015, 77.005), accuracyMeters: 5, timestamp: t.addingTimeInterval(Double(index)))
        let overflow = queue.append(fix)
        #expect(!overflow)
    }
    var transitions = 0
    var index = 0
    while let fix = queue.popFirst() {
        index += 1
        #expect(fix.timestamp == t.addingTimeInterval(Double(index)))
        let events = engine.process(fix, zones: [zone], now: fix.timestamp)
        if events.contains(.exited(zoneID: "z")) { transitions += 1; #expect(index == 3) }
    }
    #expect(index == 3)
    #expect(transitions == 1)
}

@Test func boundaryQueueSignalsDiscontinuityOnOverflow() {
    var queue = BoundaryFixQueue(capacity: 2)
    let t = Date()
    func fix(_ n: Double) -> GPSFix { GPSFix(position: GeoPoint(43, 77), accuracyMeters: 5, timestamp: t.addingTimeInterval(n)) }
    let first = queue.append(fix(1))
    let second = queue.append(fix(2))
    let third = queue.append(fix(3))
    #expect(!first)
    #expect(!second)
    #expect(third)
    let newest = queue.popFirst()
    let empty = queue.popFirst()
    #expect(newest?.timestamp == fix(3).timestamp)
    #expect(empty == nil)
    _ = queue.append(fix(4))
    queue.removeAll()
    let cleared = queue.popFirst()
    #expect(cleared == nil)
}
