import Foundation

/// Geometric events calculated locally, with a standard unobstructed horizon.
/// Low-precision lunar ephemeris is intentionally labeled approximate.
public enum FieldAstronomy {
    public struct Events: Sendable {
        public let sunrise: Date?
        public let sunset: Date?
        public let dawn: Date?
        public let dusk: Date?
        public let daylightSeconds: Double
        public let moonrise: Date?
        public let moonset: Date?
        public let illumination: Double
        public let phase: String
    }
    private static let rad = Double.pi / 180
    private static func sinD(_ x: Double) -> Double { sin(x * rad) }
    private static func cosD(_ x: Double) -> Double { cos(x * rad) }
    private static func norm(_ x: Double) -> Double { let y=x.truncatingRemainder(dividingBy:360); return y<0 ? y+360:y }
    private static func jd(_ date: Date) -> Double { date.timeIntervalSince1970/86400+2440587.5 }
    private struct Position { let ra: Double; let dec: Double; let longitude: Double }
    private static func equatorial(_ lon: Double,_ lat: Double,_ d: Double) -> Position {
        let e=23.4393-3.563e-7*d
        let x=cosD(lon)*cosD(lat)
        let y=sinD(lon)*cosD(lat)*cosD(e)-sinD(lat)*sinD(e)
        let z=sinD(lon)*cosD(lat)*sinD(e)+sinD(lat)*cosD(e)
        return Position(ra:norm(atan2(y,x)/rad),dec:atan2(z,hypot(x,y))/rad,longitude:norm(lon))
    }
    private static func sun(_ d: Double) -> Position {
        let m=norm(356.0470+0.9856002585*d)
        let w=282.9404+4.70935e-5*d
        let e=0.016709-1.151e-9*d
        let E=m+e/rad*sinD(m)*(1+e*cosD(m))
        let v=atan2(sqrt(1-e*e)*sinD(E),cosD(E)-e)/rad
        return equatorial(v+w,0,d)
    }
    private static func moon(_ d: Double) -> Position {
        let N=norm(125.1228-0.0529538083*d), i=5.1454
        let w=norm(318.0634+0.1643573223*d), m=norm(115.3654+13.0649929509*d)
        let e=0.054900
        let E=m+e/rad*sinD(m)*(1+e*cosD(m))
        let v=atan2(sqrt(1-e*e)*sinD(E),cosD(E)-e)/rad
        let x=cosD(N)*cosD(v+w)-sinD(N)*sinD(v+w)*cosD(i)
        let y=sinD(N)*cosD(v+w)+cosD(N)*sinD(v+w)*cosD(i)
        let z=sinD(v+w)*sinD(i)
        let ms=norm(356.0470+0.9856002585*d)
        let ls=norm(ms+282.9404+4.70935e-5*d)
        let lm=norm(N+w+m), D=lm-ls, F=lm-N
        var lon=atan2(y,x)/rad
        lon += -1.274*sinD(m-2*D)+0.658*sinD(2*D)-0.186*sinD(ms)
        lon += -0.059*sinD(2*m-2*D)-0.057*sinD(m-2*D+ms)+0.053*sinD(m+2*D)
        lon += 0.046*sinD(2*D-ms)+0.041*sinD(m-ms)-0.035*sinD(D)-0.031*sinD(m+ms)
        lon += -0.015*sinD(2*F-2*D)+0.011*sinD(m-4*D)
        var lat=atan2(z,hypot(x,y))/rad
        lat += -0.173*sinD(F-2*D)-0.055*sinD(m-F-2*D)-0.046*sinD(m+F-2*D)
        lat += 0.033*sinD(F+2*D)+0.017*sinD(2*m+F)
        return equatorial(lon,lat,d)
    }
    private static func altitude(_ date:Date,_ point:GeoPoint,_ lunar:Bool)->Double {
        let j=jd(date), d=j-2451543.5
        let p=lunar ? moon(d):sun(d)
        let h=norm(280.46061837+360.98564736629*(j-2451545)+point.longitude-p.ra)
        let x=sinD(point.latitude)*sinD(p.dec)+cosD(point.latitude)*cosD(p.dec)*cosD(h)
        return asin(max(-1,min(1,x)))/rad
    }
    private static func crossings(start:Date,end:Date,point:GeoPoint,lunar:Bool,threshold:Double)->(Date?,Date?,Double) {
        func value(_ date:Date)->Double { altitude(date,point,lunar)-threshold }
        var a=start, va=value(start), rise:Date?, set:Date?, duration=0.0
        while a<end {
            let b=min(a.addingTimeInterval(300),end), vb=value(b)
            if (va<0 && vb>=0)||(va>=0 && vb<0) {
                var lo=a, hi=b
                for _ in 0..<15 {
                    let mid=lo.addingTimeInterval(hi.timeIntervalSince(lo)/2)
                    if (value(mid)>=0)==(va>=0) { lo=mid } else { hi=mid }
                }
                if va<0 { if rise==nil { rise=hi }; duration += b.timeIntervalSince(hi) }
                else { if set==nil { set=hi }; duration += hi.timeIntervalSince(a) }
            } else if va>=0 { duration += b.timeIntervalSince(a) }
            a=b;va=vb
        }
        return (rise,set,duration)
    }
    public static func calculate(date:Date,point:GeoPoint,timeZone:TimeZone)->Events? {
        guard point.valid else {return nil}
        var cal=Calendar(identifier:.gregorian);cal.timeZone=timeZone
        let start=cal.startOfDay(for:date)
        guard let end=cal.date(byAdding:.day,value:1,to:start) else {return nil}
        let daylight=crossings(start:start,end:end,point:point,lunar:false,threshold:-0.833)
        let twilight=crossings(start:start,end:end,point:point,lunar:false,threshold:-6)
        let lunar=crossings(start:start,end:end,point:point,lunar:true,threshold:0.125)
        let d=jd(start.addingTimeInterval(end.timeIntervalSince(start)/2))-2451543.5
        let angle=norm(moon(d).longitude-sun(d).longitude)
        let phases=["Новолуние","Растущий серп","Первая четверть","Растущая Луна","Полнолуние","Убывающая Луна","Последняя четверть","Убывающий серп"]
        return Events(sunrise:daylight.0,sunset:daylight.1,dawn:twilight.0,dusk:twilight.1,daylightSeconds:daylight.2,moonrise:lunar.0,moonset:lunar.1,illumination:(1-cosD(angle))/2,phase:phases[Int((angle+22.5)/45)%8])
    }
}
