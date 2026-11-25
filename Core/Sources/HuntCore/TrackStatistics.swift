import Foundation

public struct TrackSample: Sendable {
    public let point:GeoPoint
    public let time:Date
    public let accuracy:Double
    public let altitude:Double?
    public let speed:Double?
    public let segmentStart:Bool
    public init(point:GeoPoint,time:Date,accuracy:Double,altitude:Double?,speed:Double?,segmentStart:Bool) {
        self.point=point;self.time=time;self.accuracy=accuracy;self.altitude=altitude;self.speed=speed;self.segmentStart=segmentStart
    }
}
public struct TrackStatistics:Sendable {
    public var distance=0.0
    public var movingSeconds=0.0
    public var stoppedSeconds=0.0
    public var gapSeconds=0.0
    public var movingDistance=0.0
    public var maximumSpeed:Double?
    public var ascent:Double?
    public var descent:Double?
    public var averageMovingSpeed:Double? {movingSeconds>0 ? movingDistance/movingSeconds:nil}
    public static func calculate(_ samples:[TrackSample])->TrackStatistics {
        var result=TrackStatistics()
        for (a,b) in zip(samples,samples.dropFirst()) {
            let dt=b.time.timeIntervalSince(a.time)
            guard dt.isFinite,dt>0 else {continue}
            guard !b.segmentStart,dt<=120,a.point.valid,b.point.valid else {result.gapSeconds+=dt;continue}
            let distance=GeoMath.meters(a.point,b.point)
            guard distance.isFinite,distance/dt<=80 else {result.gapSeconds+=dt;continue}
            result.distance+=distance
            let measured=b.speed.flatMap{$0.isFinite && $0>=0 && $0<=80 ? $0:nil}
            let speed=measured ?? distance/dt
            if speed>=0.5 {result.movingSeconds+=dt;result.movingDistance+=distance}
            else {result.stoppedSeconds+=dt}
            if let measured {result.maximumSpeed=max(result.maximumSpeed ?? 0,measured)}
            if let x=a.altitude,let y=b.altitude,x.isFinite,y.isFinite {
                if result.ascent==nil {result.ascent=0;result.descent=0}
                let delta=y-x
                // Small changes are below a conservative GPS altitude noise floor.
                if delta>=5 {result.ascent=(result.ascent ?? 0)+delta}
                if delta<=(-5) {result.descent=(result.descent ?? 0)-delta}
            }
        }
        return result
    }
}
