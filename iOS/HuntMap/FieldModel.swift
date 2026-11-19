import Foundation
import CoreLocation
import UserNotifications
import HuntCore

struct Marker: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var kind: String
    var coordinate: GeoPoint
    var createdAt: Date = Date()
}
struct TrackFix: Codable {
    var point: GeoPoint
    var timestamp: Date
    var accuracy: Double
    var altitude: Double
}
struct Track: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var fixes: [TrackFix] = []
    var distanceMeters: Double { zip(fixes, fixes.dropFirst()).reduce(0) { $0 + GeoMath.meters($1.0.point, $1.1.point) } }
}
struct LocalData: Codable { var markers:[Marker]=[]; var tracks:[Track]=[]; var pendingTrack:Track?=nil; var zones:[GeoZone]=[] }

@MainActor final class FieldModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: GeoPoint?
    @Published var accuracy: Double?
    @Published var markers: [Marker] = []
    @Published var tracks: [Track] = []
    @Published var currentTrack: Track?
    @Published var recording = false
    @Published var paused = false
    @Published var status = "GPS не запущен"
    @Published var lastWarning = "Границы не загружены"
    @Published var zones: [GeoZone] = []
    @Published var strictOffline = true
    @Published var gpsAuthorization = "не определено"
    @Published var lastError = ""
    private let manager=CLLocationManager()
    private let engine=BoundaryEngine()
    private var lastFix: CLLocation?
    private var documentURL:URL {
        let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir.appendingPathComponent("field.json")
    }
    override init() {
        super.init()
        manager.delegate=self
        manager.desiredAccuracy=kCLLocationAccuracyBest
        manager.distanceFilter=5
        load()
        // Do not silently inject example hunting boundaries in a real user's location.
    }
    func requestGPS() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse { manager.startUpdatingLocation() }
        else { status = "Разрешите геолокацию в настройках iPhone" }
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { _,_ in }
    }
    func requestBackgroundGPS() {
        if manager.authorizationStatus == .authorizedWhenInUse { manager.requestAlwaysAuthorization() }
        else if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else { status = manager.authorizationStatus == .authorizedAlways ? "Фоновый GPS разрешён" : "Проверьте доступ к геолокации в настройках" }
    }
    func startTrack() {
        guard !recording else {return}
        guard CLLocationManager.locationServicesEnabled() else {
            status = "GPS выключен в настройках iPhone"; lastError = status; return
        }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            status = "Дайте разрешение GPS, затем повторите запись"
            lastError = status
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            return
        }
        currentTrack=Track(name:"Маршрут \(Date.now.formatted(date:.numeric,time:.shortened))")
        recording=true;paused=false
        // Background updates are enabled ONLY after Always authorization; foreground-only
        // recording must never terminate the app because the user denied Always access.
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
        }
        manager.startUpdatingLocation()
        status = manager.authorizationStatus == .authorizedAlways ? "Запись: фон разрешён" : "Запись: только на экране; для фона разрешите «Всегда»"
        persist()
    }
    func togglePause() { paused.toggle(); persist() }
    func stopTrack() {
        guard recording else {return}
        if let track=currentTrack, !track.fixes.isEmpty {tracks.insert(track,at:0)}
        currentTrack=nil;recording=false;paused=false
        if manager.allowsBackgroundLocationUpdates { manager.allowsBackgroundLocationUpdates=false }
        manager.pausesLocationUpdatesAutomatically=true
        persist()
    }
    func addMarker(kind:String="Точка") {
        guard let coordinate else { status="Сначала получите GPS-позицию"; return }
        markers.insert(Marker(title:"\(kind) \(markers.count+1)",kind:kind,coordinate:coordinate),at:0)
        persist()
    }
    func removeMarkers(at offsets:IndexSet) {markers.remove(atOffsets:offsets);persist()}
    func setImportedZones(_ imported:[GeoZone]) { zones=imported; lastWarning="Импортированные границы юридически не проверены"; persist() }
    func loadDemoZones() {
        // Illustrative polygon only: NOT an actual hunting ground or legal boundary.
        let polygon=GeoPolygon(rings:[[GeoPoint(43.245,76.88),GeoPoint(43.245,76.92),GeoPoint(43.275,76.92),GeoPoint(43.275,76.88)]])
        zones=[GeoZone(id:"DEMO-NOT-LEGAL",name:"Демо-территория (не охотугодье)",kind:.huntingGround,verified:false,source:"Синтетический тестовый полигон",polygons:[polygon])]
        lastWarning="Демонстрационные границы. Не использовать для охоты"
        persist()
    }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        guard let fix=locations.last,fix.horizontalAccuracy>=0,Date().timeIntervalSince(fix.timestamp)<30 else {return}
        let p=GeoPoint(fix.coordinate.latitude,fix.coordinate.longitude)
        guard p.valid else {return}
        coordinate=p;accuracy=fix.horizontalAccuracy
        status="GPS ±\(Int(fix.horizontalAccuracy)) м"
        if recording && !paused {
            if let last=lastFix, abs(fix.timestamp.timeIntervalSince(last.timestamp))<1 {return}
            if let last=lastFix {
                let dt=fix.timestamp.timeIntervalSince(last.timestamp)
                if dt>0 && GeoMath.meters(GeoPoint(last.coordinate.latitude,last.coordinate.longitude),p)/dt>80 {return}
            }
            currentTrack?.fixes.append(TrackFix(point:p,timestamp:fix.timestamp,accuracy:fix.horizontalAccuracy,altitude:fix.altitude))
            persist() // Atomic write of current track after each accepted fix.
        }
        lastFix=fix
        for event in engine.process(GPSFix(position:p,accuracyMeters:fix.horizontalAccuracy,timestamp:fix.timestamp),zones:zones) {
            let message:String
            switch event {
            case .approaching(_,let meters):message="Граница на расстоянии около \(meters) м"
            case .uncertain:message="Положение относительно границы не определено"
            case .entered:message="Пересечение: вход в геозону"
            case .exited:message="Пересечение: выход из геозоны"
            }
            lastWarning=message
            let notification=UNMutableNotificationContent()
            notification.title="HUNT MAP KZ";notification.body=message;notification.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier:UUID().uuidString,content:notification,trigger:nil))
        }
    }
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) {status="Ошибка GPS: \(error.localizedDescription)"; lastError = status}
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {manager.startUpdatingLocation()}
        gpsAuthorization = String(describing: manager.authorizationStatus.rawValue)
        if manager.authorizationStatus == .denied {status="Нет разрешения геолокации"; lastError=status}
    }
    private func load() {
        guard let bytes=try? Data(contentsOf:documentURL),let obj=try? JSONDecoder().decode(LocalData.self,from:bytes) else {return}
        markers=obj.markers;tracks=obj.tracks;zones=obj.zones
        if let pending=obj.pendingTrack {tracks.insert(Track(id:pending.id,name:pending.name+" (восстановлен)",createdAt:pending.createdAt,fixes:pending.fixes),at:0)}
    }
    private func persist() {
        guard let encoded=try? JSONEncoder().encode(LocalData(markers:markers,tracks:tracks,pendingTrack:currentTrack,zones:zones)) else {return}
        try? encoded.write(to:documentURL,options:[.atomic,.completeFileProtectionUnlessOpen])
    }
    func exportGPX(_ track:Track)->URL? {
        func xml(_ s:String)->String {s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
        let points=track.fixes.map { f in "<trkpt lat=\"\(f.point.latitude)\" lon=\"\(f.point.longitude)\"><time>\(ISO8601DateFormatter().string(from:f.timestamp))</time></trkpt>" }.joined()
        let data="<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"HUNT MAP KZ\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(xml(track.name))</name><trkseg>\(points)</trkseg></trk></gpx>"
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("route-\(track.id).gpx")
        do {try data.write(to:url,atomically:true,encoding:.utf8);return url} catch {return nil}
    }
}
