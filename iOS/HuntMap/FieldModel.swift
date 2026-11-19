import Foundation
import CoreLocation
import UserNotifications
import HuntCore
import WidgetKit

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
    // Optional for backward compatibility with previously saved routes.
    var startsNewSegment: Bool? = nil
}
struct Track: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var fixes: [TrackFix] = []
    // Optional to preserve decoding of routes saved by previous app versions.
    // New recordings update this accumulator in O(1) per accepted GPS fix.
    var accumulatedDistanceMeters: Double? = nil
    var distanceMeters: Double {
        if let accumulatedDistanceMeters, accumulatedDistanceMeters.isFinite, accumulatedDistanceMeters >= 0 {
            return accumulatedDistanceMeters
        }
        return zip(fixes, fixes.dropFirst()).reduce(0) { total, pair in
            pair.1.startsNewSegment == true ? total : total + GeoMath.meters(pair.0.point, pair.1.point)
        }
    }
    mutating func appendAcceptedFix(_ fix: TrackFix) {
        let oldDistance = distanceMeters
        let increment: Double
        if fix.startsNewSegment == true || fixes.isEmpty { increment = 0 }
        else { increment = GeoMath.meters(fixes[fixes.count - 1].point, fix.point) }
        fixes.append(fix)
        accumulatedDistanceMeters = oldDistance + (increment.isFinite ? max(0, increment) : 0)
    }
}
struct LocalData: Codable { var markers:[Marker]=[]; var tracks:[Track]=[]; var pendingTrack:Track?=nil; var zones:[GeoZone]=[] }

@MainActor final class FieldModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: GeoPoint?
    @Published var accuracy: Double?
    @Published var travelHeading: Double?
    @Published var gpsFixAgeSeconds: Double?
    @Published var gpsSignalQuality = "Нет сигнала"
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
    private var lastAcceptedTrackFix: CLLocation?
    private var startNextTrackSegment = true
    private var lastPersistedTrackAt = Date.distantPast
    private var lastWidgetSnapshotAt = Date.distantPast
    // Incremental crash-recovery journal avoids re-encoding the entire route for every fix.
    private struct JournalFix: Codable { let trackID: UUID; let fix: TrackFix }
    private var journalURL: URL { documentURL.deletingLastPathComponent().appendingPathComponent("track-fixes.jsonl") }
    private func appendJournal(_ fix: TrackFix, trackID: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(JournalFix(trackID: trackID, fix: fix)) else { return false }
        do {
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                try Data().write(to: journalURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            }
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data + Data([10]))
            try handle.synchronize()
            return true
        } catch { lastError = "Ошибка сохранения GPS-точки: \(error.localizedDescription)"; return false }
    }
    private func replayJournal(into track: inout Track) {
        guard let data = try? Data(contentsOf: journalURL), !data.isEmpty else { return }
        let decoder = JSONDecoder()
        var latest = track.fixes.last?.timestamp ?? .distantPast
        for line in data.split(separator: 10) {
            guard let item = try? decoder.decode(JournalFix.self, from: Data(line)),
                  item.trackID == track.id, item.fix.timestamp > latest else { continue }
            track.appendAcceptedFix(item.fix)
            latest = item.fix.timestamp
        }
    }
    private func removeJournal() { try? FileManager.default.removeItem(at: journalURL) }
    func flushPendingRoute() { persist() }
    private var lastHeadingTime: Date?
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
        manager.activityType = .fitness
        manager.headingFilter = 5
        load()
        // Do not silently inject example hunting boundaries in a real user's location.
    }
    func requestGPS() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse { startLocationServices() }
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
        lastAcceptedTrackFix = nil
        startNextTrackSegment = true
        // A new recording never inherits journal entries from an older session.
        // Do not discard a previous recovery journal unless the new session can be snapshotted.
        currentTrack=Track(name:"Маршрут \(Date.now.formatted(date:.numeric,time:.shortened))")
        recording=true;paused=false
        // Background updates are enabled ONLY after Always authorization; foreground-only
        // recording must never terminate the app because the user denied Always access.
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
        }
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = 3
        startLocationServices()
        status = manager.authorizationStatus == .authorizedAlways ? "Запись: фон разрешён" : "Запись: только на экране; для фона разрешите «Всегда»"
        persist()
    }
    func togglePause() { paused.toggle(); if !paused { lastAcceptedTrackFix = nil; startNextTrackSegment = true }; persist() }
    func stopTrack() {
        guard recording else {return}
        if let track=currentTrack, !track.fixes.isEmpty {tracks.insert(track,at:0)}
        currentTrack=nil;recording=false;paused=false
        if manager.allowsBackgroundLocationUpdates { manager.allowsBackgroundLocationUpdates=false }
        manager.pausesLocationUpdatesAutomatically=true
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        lastAcceptedTrackFix = nil
        startNextTrackSegment = true
        persist()
    }
    func addMarker(kind:String="Точка") {
        guard let coordinate else { status="Сначала получите GPS-позицию"; return }
        markers.insert(Marker(title:"\(kind) \(markers.count+1)",kind:kind,coordinate:coordinate),at:0)
        persist()
    }
    /// Save a manually selected location even when GPS and cellular service are unavailable.
    func addMarker(kind: String, at point: GeoPoint) {
        markers.insert(Marker(title: "\(kind) \(markers.count + 1)", kind: kind, coordinate: point), at: 0)
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
    private func startLocationServices() {
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard heading.headingAccuracy >= 0 else { return }
        // Course from GPS has priority while moving; compass is useful when stationary.
        if let fix = lastFix, fix.speed >= 0.8, fix.course >= 0 { return }
        let value = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        guard value.isFinite && value >= 0 else { return }
        travelHeading = value
        lastHeadingTime = Date()
    }
    func locationManager(_ manager:CLLocationManager,didUpdateLocations locations:[CLLocation]) {
        // Process in timestamp order, so stale fixes never overwrite a newer position.
        for fix in locations.sorted(by: { $0.timestamp < $1.timestamp }) {
            let age = Date().timeIntervalSince(fix.timestamp)
            guard age >= -2 && age <= 15, fix.horizontalAccuracy >= 0,
                  fix.horizontalAccuracy <= 150, fix.coordinate.latitude.isFinite,
                  fix.coordinate.longitude.isFinite else { continue }
            let p = GeoPoint(fix.coordinate.latitude,fix.coordinate.longitude)
            guard p.valid else { continue }
            if let previous = lastFix {
                let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
                guard dt > 0 else { continue }
                let distance = GeoMath.meters(GeoPoint(previous.coordinate.latitude,previous.coordinate.longitude),p)
                // Allow a jump only if it could be explained by both fixes' uncertainty.
                let uncertainty = previous.horizontalAccuracy + fix.horizontalAccuracy
                if distance > uncertainty + max(35, dt * 55) { continue }
            }
            lastFix = fix
            coordinate = p
            accuracy = fix.horizontalAccuracy
            gpsFixAgeSeconds = age
            gpsSignalQuality = fix.horizontalAccuracy <= 10 ? "Отличный" : (fix.horizontalAccuracy <= 30 ? "Хороший" : "Слабый")
            if fix.course >= 0 && fix.speed >= 0.8 { travelHeading = fix.course }
            status = "GPS ±\(Int(fix.horizontalAccuracy)) м · \(gpsSignalQuality)"
            if recording && !paused {
                // Low-quality fixes are shown as GPS status, never drawn as route geometry.
                // A prolonged outage starts a new segment instead of drawing a straight
                // line across a tunnel, valley or a period without satellite reception.
                if fix.horizontalAccuracy <= 35 {
                    var append = true
                    if let previous = lastAcceptedTrackFix {
                        let dt = fix.timestamp.timeIntervalSince(previous.timestamp)
                        let distance = GeoMath.meters(GeoPoint(previous.coordinate.latitude,previous.coordinate.longitude),p)
                        let gap = dt > 45
                        if gap { startNextTrackSegment = true }
                        let uncertainty = hypot(previous.horizontalAccuracy, fix.horizontalAccuracy)
                        let stationary = fix.speed >= 0 && fix.speed < 0.6
                        // Adaptive threshold suppresses stationary jitter but retains
                        // short walking movements when the GNSS accuracy is good.
                        let threshold = max(2.5, min(15, uncertainty * (stationary ? 0.8 : 0.45)))
                        let impossible = dt <= 0 || (dt < 45 && distance > uncertainty + dt * 45)
                        if impossible {
                            append = false
                        } else if !gap && distance < threshold {
                            append = false
                        } else if !gap && stationary && distance < max(8, uncertainty) {
                            append = false
                        }
                    }
                    if append {
                        let accepted = TrackFix(point:p,timestamp:fix.timestamp,
                            accuracy:fix.horizontalAccuracy,altitude:fix.altitude,
                            startsNewSegment:startNextTrackSegment)
                        // Persist the small record before mutating the in-memory route.
                        // If journaling fails, use the full snapshot as a fallback.
                        let journaled = currentTrack.map { appendJournal(accepted, trackID: $0.id) } ?? false
                        currentTrack?.appendAcceptedFix(accepted)
                        lastAcceptedTrackFix = fix
                        startNextTrackSegment = false
                        // The on-map UI uses the live model; WidgetKit receives a throttled snapshot.
                        if Date().timeIntervalSince(lastWidgetSnapshotAt) >= 5 { publishRouteWidget() }
                        if !journaled || Date().timeIntervalSince(lastPersistedTrackAt) >= 20 {
                            persist()
                        }
                    }
                } else if let previous = lastAcceptedTrackFix,
                          fix.timestamp.timeIntervalSince(previous.timestamp) > 45 {
                    startNextTrackSegment = true
                }
            }
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
    }
    func locationManager(_ manager:CLLocationManager,didFailWithError error:Error) {status="Ошибка GPS: \(error.localizedDescription)"; lastError = status}
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {startLocationServices()}
        gpsAuthorization = String(describing: manager.authorizationStatus.rawValue)
        if manager.authorizationStatus == .denied {status="Нет разрешения геолокации"; lastError=status}
    }
    private func load() {
        guard let bytes = try? Data(contentsOf: documentURL) else { return }
        guard let obj = try? JSONDecoder().decode(LocalData.self, from: bytes) else {
            lastError = "Не удалось прочитать сохранённые маршруты. Исходный файл не изменён"
            return
        }
        markers=obj.markers;tracks=obj.tracks;zones=obj.zones
        if var pending=obj.pendingTrack {
            replayJournal(into: &pending)
            pending.name += " (восстановлен)"
            tracks.insert(pending, at: 0)
            // Preserve recovered points in the next snapshot before clearing the journal.
            persist()
        }
    }
    var currentSpeedKmh: Double? {
        guard recording, !paused, let fix = lastFix,
              Date().timeIntervalSince(fix.timestamp) <= 10,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= 35,
              fix.speed >= 0, fix.speed.isFinite else { return nil }
        return max(0, fix.speed * 3.6)
    }
    var averagePaceSecondsPerKm: Double? {
        guard let route = currentTrack, route.distanceMeters >= 10 else { return nil }
        let seconds = max(0, Date().timeIntervalSince(route.createdAt))
        return seconds * 1000 / route.distanceMeters
    }
    private func publishRouteWidget() {
        lastWidgetSnapshotAt = Date()
        let route = currentTrack
        let snapshot = RouteWidgetSnapshot(
            title: route?.name ?? "Маршрут не записывается",
            status: recording ? (paused ? "Пауза" : "Запись маршрута") : "Нет активной записи",
            distanceMeters: route?.distanceMeters ?? 0,
            elapsedSeconds: route.map { Date().timeIntervalSince($0.createdAt) } ?? 0,
            pointCount: route?.fixes.count ?? 0,
            speedKmh: currentSpeedKmh,
            averagePaceSecondsPerKm: averagePaceSecondsPerKm,
            updatedAt: .now)
        RouteWidgetStorage.write(snapshot)
        // WidgetKit budgets updates: do not request a refresh for every GPS fix.
        let defaults = UserDefaults(suiteName: RouteWidgetStorage.suite)
        let previous = defaults?.double(forKey: "routeWidgetLastReload") ?? 0
        if !recording || Date().timeIntervalSince1970 - previous > 60 {
            defaults?.set(Date().timeIntervalSince1970, forKey: "routeWidgetLastReload")
            WidgetCenter.shared.reloadTimelines(ofKind: "HuntMapRouteWidget")
        }
    }
    private func persist() {
        publishRouteWidget()
        guard let encoded=try? JSONEncoder().encode(LocalData(markers:markers,tracks:tracks,pendingTrack:currentTrack,zones:zones)) else {return}
        do {
            try encoded.write(to:documentURL,options:[.atomic,.completeFileProtectionUnlessOpen])
            lastPersistedTrackAt = Date()
            removeJournal() // Only after a successful atomic snapshot.
        } catch { lastError = "Ошибка сохранения маршрута: \(error.localizedDescription)" }
    }
    func exportGPX(_ track:Track)->URL? {
        func xml(_ s:String)->String {s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
        var segments: [String] = []
        var points = ""
        for f in track.fixes {
            if f.startsNewSegment == true && !points.isEmpty {
                segments.append("<trkseg>\(points)</trkseg>")
                points = ""
            }
            points += "<trkpt lat=\"\(f.point.latitude)\" lon=\"\(f.point.longitude)\"><time>\(ISO8601DateFormatter().string(from:f.timestamp))</time><ele>\(f.altitude)</ele></trkpt>"
        }
        if !points.isEmpty { segments.append("<trkseg>\(points)</trkseg>") }
        let data="<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"HUNT MAP KZ\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(xml(track.name))</name>\(segments.joined())</trk></gpx>"
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("route-\(track.id).gpx")
        do {try data.write(to:url,atomically:true,encoding:.utf8);return url} catch {return nil}
    }
}
