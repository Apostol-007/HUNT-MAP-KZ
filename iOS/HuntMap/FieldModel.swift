import Foundation
import CoreLocation
import UserNotifications
import AudioToolbox
import UIKit
import HuntCore

struct Marker: Identifiable, Codable {
    var id: UUID = UUID()
    var title: String
    var kind: String
    var coordinate: GeoPoint
    var createdAt: Date = Date()
    // Optional styling metadata keeps older saved marker JSON compatible.
    var symbol: String? = nil
    var colorHex: String? = nil
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
    /// Elapsed time between first and last accepted fix; does not invent time for empty tracks.
    var durationSeconds: TimeInterval {
        guard let start = fixes.first?.timestamp, let finish = fixes.last?.timestamp else { return 0 }
        return max(0, finish.timeIntervalSince(start))
    }
}
struct LocalData: Codable { var markers:[Marker]=[]; var tracks:[Track]=[]; var pendingTrack:Track?=nil; var zones:[GeoZone]=[] }

@MainActor final class FieldModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: GeoPoint?
    @Published var accuracy: Double?
    @Published var markers: [Marker] = []
    @Published var tracks: [Track] = []
    @Published var currentTrack: Track?
    @Published var recording = false
    @Published private(set) var navigatingRecordedTrack = false
    @Published var paused = false
    @Published var status = "GPS не запущен"
    @Published var lastWarning = "Границы не загружены"
    @Published var zones: [GeoZone] = []
    @Published var strictOffline = true
    @Published var gpsAuthorization = "не определено"
    @Published var lastError = ""
    private let manager=CLLocationManager()
    private var engine=BoundaryEngine()
    @Published private(set) var monitoredGroundID: String?
    @Published private(set) var groundMonitorStatus = "Контроль выключен"
    private var groundLastTimestamp: Date?
    private var groundWasInside = false
    private var groundOutsideCount = 0
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
    func startRecordedRouteGuidance() {
        navigatingRecordedTrack = true
        requestGPS()
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
        } else {
            status = "Ведение по маршруту: GPS на экране. Для фонового режима разрешите доступ «Всегда»."
        }
    }

    func stopRecordedRouteGuidance() {
        navigatingRecordedTrack = false
        if !recording && monitoredGroundID == nil {
            manager.allowsBackgroundLocationUpdates = false
            manager.pausesLocationUpdatesAutomatically = true
        }
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
        lastFix=nil // Do not reuse the last fix from a previous recording session.
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
    func togglePause() {
        guard recording else { return }
        paused.toggle()
        lastFix = nil // A paused interval must not create a jump when recording resumes.
        status = paused ? "Запись приостановлена" : "Запись продолжена"
        persist()
    }
    func stopTrack() {
        guard recording else {return}
        if let track=currentTrack, !track.fixes.isEmpty {tracks.insert(track,at:0)}
        currentTrack=nil;recording=false;paused=false
        lastFix=nil
        if manager.allowsBackgroundLocationUpdates && !navigatingRecordedTrack && monitoredGroundID == nil { manager.allowsBackgroundLocationUpdates=false }
        manager.pausesLocationUpdatesAutomatically = !navigatingRecordedTrack && monitoredGroundID == nil
        persist()
    }
    func addMarker(kind:String="Точка") {
        guard let coordinate else { status="Сначала получите GPS-позицию"; return }
        markers.insert(Marker(title:"\(kind) \(markers.count+1)",kind:kind,coordinate:coordinate),at:0)
        persist()
    }
    @discardableResult
    func addMarker(at point: GeoPoint, kind: String = "Точка") -> Marker? {
        guard point.valid else { status = "Недопустимые координаты метки"; return nil }
        let marker = Marker(title: "\(kind) \(markers.count + 1)", kind: kind, coordinate: point)
        markers.insert(marker, at: 0)
        persist()
        return marker
    }
    func removeMarkers(at offsets:IndexSet) {markers.remove(atOffsets:offsets);persist()}
    func insertMarker(_ marker: Marker) {
        guard marker.coordinate.valid else { status = "Недопустимые координаты метки"; return }
        guard !markers.contains(where: { $0.id == marker.id }) else { return }
        markers.insert(marker, at: 0)
        persist()
    }
    func saveMarker(_ changed: Marker) {
        guard let index = markers.firstIndex(where: { $0.id == changed.id }) else { return }
        markers[index] = changed
        persist()
    }
    func deleteMarker(id: UUID) {
        markers.removeAll { $0.id == id }
        persist()
    }
    func deleteTrack(id: UUID) {
        tracks.removeAll { $0.id == id }
        persist()
    }
    func setImportedZones(_ imported:[GeoZone]) {
        let existing = Dictionary(zones.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = existing
        for ground in imported where existing[ground.id] == nil { merged[ground.id] = ground }
        zones = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lastWarning = "Импортированные границы юридически не проверены"
        persist()
    }
    func saveGround(_ ground: GeoZone) {
        if let index = zones.firstIndex(where: { $0.id == ground.id }) { zones[index] = ground }
        else { zones.append(ground) }
        if monitoredGroundID == ground.id { groundWasInside = false; groundOutsideCount = 0 }
        persist()
    }
    func deleteGround(_ id: String) {
        if monitoredGroundID == id { stopGroundMonitor() }
        zones.removeAll { $0.id == id }
        persist()
    }
    func startGroundMonitor(_ ground: GeoZone) {
        monitoredGroundID = ground.id
        groundLastTimestamp = nil
        groundWasInside = false
        groundOutsideCount = 0
        groundMonitorStatus = "Ожидание точной GPS-позиции внутри угодья"
        requestGPS()
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
        }
    }
    func stopGroundMonitor() {
        monitoredGroundID = nil
        groundMonitorStatus = "Контроль выключен"
        if !recording && !navigatingRecordedTrack {
            manager.allowsBackgroundLocationUpdates = false
            manager.pausesLocationUpdatesAutomatically = true
        }
    }
    private func checkSelectedGround(_ fix: CLLocation, point: GeoPoint) {
        guard let id = monitoredGroundID, let ground = zones.first(where: { $0.id == id }) else { return }
        guard groundLastTimestamp == nil || fix.timestamp > groundLastTimestamp! else { return }
        groundLastTimestamp = fix.timestamp
        guard fix.horizontalAccuracy <= 50, ground.distanceToBoundaryMeters(point) > fix.horizontalAccuracy + 20 else {
            groundOutsideCount = 0
            groundMonitorStatus = "Уточнение положения у границы"
            return
        }
        if ground.contains(point) {
            groundWasInside = true
            groundOutsideCount = 0
            groundMonitorStatus = "Внутри: " + ground.name
        } else if groundWasInside {
            groundOutsideCount += 1
            if groundOutsideCount >= 3 {
                groundWasInside = false
                groundOutsideCount = 0
                groundMonitorStatus = "Вы вышли за пределы: " + ground.name
                lastWarning = groundMonitorStatus
                if UIApplication.shared.applicationState == .active {
                    AudioServicesPlayAlertSound(1005)
                    AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
                }
                let notification = UNMutableNotificationContent()
                notification.title = "Выход из охотугодья"
                notification.body = ground.name
                notification.sound = .default
                UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: notification, trigger: nil))
            }
        } else { groundMonitorStatus = "Вне угодья: " + ground.name }
    }
    func loadDemoZones() {
        // Illustrative polygon only: NOT an actual hunting ground or legal boundary.
        let polygon=GeoPolygon(rings:[[GeoPoint(43.245,76.88),GeoPoint(43.245,76.92),GeoPoint(43.275,76.92),GeoPoint(43.275,76.88)]])
        zones=[GeoZone(id:"DEMO-NOT-LEGAL",name:"Демо-территория (не охотугодье)",kind:.huntingGround,verified:false,source:"Синтетический тестовый полигон",polygons:[polygon])]
        lastWarning="Демонстрационные границы. Не использовать для охоты"
        persist()
    }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        guard let fix=locations.last,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 100,
              Date().timeIntervalSince(fix.timestamp) >= -5,
              Date().timeIntervalSince(fix.timestamp) < 30 else {return}
        let p=GeoPoint(fix.coordinate.latitude,fix.coordinate.longitude)
        guard p.valid else {return}
        coordinate=p;accuracy=fix.horizontalAccuracy
        status="GPS ±\(Int(fix.horizontalAccuracy)) м"
        checkSelectedGround(fix, point: p)
        if recording && !paused {
            if let last=lastFix, fix.timestamp.timeIntervalSince(last.timestamp)<1 {return}
            if let last=lastFix {
                let dt=fix.timestamp.timeIntervalSince(last.timestamp)
                if dt>0 && GeoMath.meters(GeoPoint(last.coordinate.latitude,last.coordinate.longitude),p)/dt>80 {return}
            }
            currentTrack?.fixes.append(TrackFix(point:p,timestamp:fix.timestamp,accuracy:fix.horizontalAccuracy,altitude:fix.altitude))
            persist() // Atomic write of current track after each accepted fix.
        }
        lastFix=fix
        for event in engine.process(GPSFix(position:p,accuracyMeters:fix.horizontalAccuracy,timestamp:fix.timestamp),zones:zones.filter { $0.kind == .protectedArea }) {
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
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = "Ошибка GPS: \(error.localizedDescription)"
        lastError = status
        AppDiagnosticLog.shared.recordError(subsystem: "GPS",
            operation: "Получение координат", error: error)
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            if manager.authorizationStatus == .authorizedAlways && (navigatingRecordedTrack || monitoredGroundID != nil) {
                manager.allowsBackgroundLocationUpdates = true
                manager.pausesLocationUpdatesAutomatically = false
            }
            manager.startUpdatingLocation()
        }
        gpsAuthorization = String(describing: manager.authorizationStatus.rawValue)
        if manager.authorizationStatus == .denied {status="Нет разрешения геолокации"; lastError=status}
    }
    private func load() {
        guard let bytes=try? Data(contentsOf:documentURL),let obj=try? JSONDecoder().decode(LocalData.self,from:bytes) else {return}
        markers=obj.markers;tracks=obj.tracks;zones=obj.zones
        // An interrupted recording is restored exactly once. Clear pendingTrack on disk
        // immediately, otherwise every relaunch would duplicate the recovered route.
        if let pending=obj.pendingTrack {
            if !pending.fixes.isEmpty && !tracks.contains(where: { $0.id == pending.id }) {
                tracks.insert(Track(id:pending.id, name:pending.name+" (восстановлен)",
                                    createdAt:pending.createdAt, fixes:pending.fixes), at:0)
            }
            lastWarning = "Запись после закрытия приложения восстановлена"
            persist()
        }
    }
    private func persist() {
        guard let encoded=try? JSONEncoder().encode(LocalData(markers:markers,tracks:tracks,pendingTrack:currentTrack,zones:zones)) else {return}
        try? encoded.write(to:documentURL,options:[.atomic,.completeFileProtectionUnlessOpen])
    }
    func exportGPX(_ track:Track)->URL? {
        func xml(_ s:String)->String {s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let points = track.fixes.map { fix -> String in
            let elevation = fix.altitude.isFinite ? "<ele>\(fix.altitude)</ele>" : ""
            return "<trkpt lat=\"\(fix.point.latitude)\" lon=\"\(fix.point.longitude)\">\(elevation)<time>\(formatter.string(from:fix.timestamp))</time></trkpt>"
        }.joined()
        let data="<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"HUNT MAP KZ\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(xml(track.name))</name><trkseg>\(points)</trkseg></trk></gpx>"
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("route-\(track.id).gpx")
        do {try data.write(to:url,atomically:true,encoding:.utf8);return url} catch {return nil}
    }
}
