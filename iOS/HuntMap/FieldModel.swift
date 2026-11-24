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
    @Published var zones: [GeoZone] = [] { didSet { zoneRevision += 1 } }
    @Published var strictOffline = true
    @Published var gpsAuthorization = "не определено"
    @Published var lastError = ""
    private let manager=CLLocationManager()
    private let boundaryWorker = BoundaryWorker()
    private var boundaryTask: Task<Void, Never>?
    private var pendingBoundaryFix: GPSFix?
    private var zoneRevision = 0
    private var lastFix: CLLocation?
    private let trackJournal = TrackPointJournal()
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
        if !recording {
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
        if let currentTrack { trackJournal.begin(track: currentTrack) }
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
        if manager.allowsBackgroundLocationUpdates && !navigatingRecordedTrack { manager.allowsBackgroundLocationUpdates=false }
        manager.pausesLocationUpdatesAutomatically = !navigatingRecordedTrack
        persist()
        // Clear only after the completed track has been committed to field.json.
        // If JSON persistence fails, the journal remains available for recovery.
        if let data = try? Data(contentsOf: documentURL),
           let saved = try? JSONDecoder().decode(LocalData.self, from: data),
           saved.pendingTrack == nil {
            trackJournal.clear()
        }
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
    func setImportedZones(_ imported:[GeoZone]) { zones=imported; lastWarning="Импортированные границы юридически не проверены"; persist() }
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
        if recording && !paused {
            if let last=lastFix, fix.timestamp.timeIntervalSince(last.timestamp)<1 {return}
            if let last=lastFix {
                let dt=fix.timestamp.timeIntervalSince(last.timestamp)
                if dt>0 && GeoMath.meters(GeoPoint(last.coordinate.latitude,last.coordinate.longitude),p)/dt>80 {return}
            }
            let point = TrackFix(point:p,timestamp:fix.timestamp,accuracy:fix.horizontalAccuracy,altitude:fix.altitude)
            currentTrack?.fixes.append(point)
            // Append one SQLite row, never re-encode all saved routes on every GPS update.
            // If SQLite is unavailable, preserve the previous full-JSON persistence.
            if !trackJournal.append(point) { persist() }
        }
        lastFix=fix
        pendingBoundaryFix = GPSFix(position:p,accuracyMeters:fix.horizontalAccuracy,timestamp:fix.timestamp)
        scheduleBoundaryCheck()
    }

    private func scheduleBoundaryCheck() {
        guard boundaryTask == nil else { return }
        boundaryTask = Task { [weak self] in
            guard let self else { return }
            while let fix = self.pendingBoundaryFix {
                self.pendingBoundaryFix = nil
                let revision = self.zoneRevision
                let snapshot = self.zones
                let events = await self.boundaryWorker.process(fix, zones: snapshot, revision: revision)
                guard !Task.isCancelled else { break }
                if revision == self.zoneRevision {
                    for event in events { self.publishBoundaryEvent(event) }
                }
            }
            self.boundaryTask = nil
        }
    }

    private func publishBoundaryEvent(_ event: BoundaryEvent) {
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
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = "Ошибка GPS: \(error.localizedDescription)"
        lastError = status
        AppDiagnosticLog.shared.recordError(subsystem: "GPS",
            operation: "Получение координат", error: error)
    }
    func locationManagerDidChangeAuthorization(_ manager:CLLocationManager) {
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            if manager.authorizationStatus == .authorizedAlways && navigatingRecordedTrack {
                manager.allowsBackgroundLocationUpdates = true
                manager.pausesLocationUpdatesAutomatically = false
            }
            manager.startUpdatingLocation()
        }
        gpsAuthorization = String(describing: manager.authorizationStatus.rawValue)
        if manager.authorizationStatus == .denied {status="Нет разрешения геолокации"; lastError=status}
    }
    private func load() {
        guard let bytes = try? Data(contentsOf: documentURL),
              let obj = try? JSONDecoder().decode(LocalData.self, from: bytes) else {
            // Never overwrite a malformed legacy file without preserving it.
            if FileManager.default.fileExists(atPath: documentURL.path) {
                let destination = documentURL.deletingLastPathComponent()
                    .appendingPathComponent("field-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: documentURL, to: destination)
            }
            recoverOrphanedJournal()
            return
        }
        markers=obj.markers;tracks=obj.tracks;zones=obj.zones
        // An interrupted recording is restored exactly once. Clear pendingTrack on disk
        // immediately, otherwise every relaunch would duplicate the recovered route.
        if var pending=obj.pendingTrack {
            // The SQLite journal is authoritative for the active recording. Legacy
            // pending fixes are retained when migrating from an older installed IPA.
            let journalFixes = trackJournal.read(trackID: pending.id)
            if journalFixes.count > pending.fixes.count { pending.fixes = journalFixes }
            if !pending.fixes.isEmpty && !tracks.contains(where: { $0.id == pending.id }) {
                tracks.insert(Track(id:pending.id, name:pending.name+" (восстановлен)",
                                    createdAt:pending.createdAt, fixes:pending.fixes), at:0)
            }
            lastWarning = "Запись после закрытия приложения восстановлена"
            persist()
            // Delete recovered fixes only once the restored state is on disk.
            if let data = try? Data(contentsOf: documentURL),
               let saved = try? JSONDecoder().decode(LocalData.self, from: data),
               saved.pendingTrack == nil { trackJournal.clear() }
        } else {
            // A previous JSON commit may not contain pendingTrack if it was
            // interrupted. Recover surviving SQLite rows exactly once by UUID.
            recoverOrphanedJournal()
        }
    }

    private func recoverOrphanedJournal() {
        guard var recovered = trackJournal.recoverableTrack() else { return }
        guard !tracks.contains(where: { $0.id == recovered.id }) else {
            trackJournal.clear()
            return
        }
        recovered.name += " (восстановлен)"
        tracks.insert(recovered, at: 0)
        lastWarning = "GPS-маршрут восстановлен из журнала после сбоя"
        persist()
        if let data = try? Data(contentsOf: documentURL),
           let saved = try? JSONDecoder().decode(LocalData.self, from: data),
           saved.tracks.contains(where: { $0.id == recovered.id }) {
            trackJournal.clear()
        }
    }
    private func persist() {
        guard let encoded=try? JSONEncoder().encode(LocalData(markers:markers,tracks:tracks,pendingTrack:currentTrack,zones:zones)) else {return}
        try? encoded.write(to:documentURL,options:[.atomic,.completeFileProtectionUnlessOpen])
    }
    /// Explicit user-controlled export. Includes an active recording from
    /// the crash-safe SQLite journal and leaves all local files unchanged.
    func exportBackup() -> URL? {
        var active = currentTrack
        if var pending = active {
            let saved = trackJournal.read(trackID: pending.id)
            if saved.count > pending.fixes.count { pending.fixes = saved }
            active = pending
        }
        let snapshot = LocalData(markers: markers, tracks: tracks,
                                 pendingTrack: active, zones: zones)
        guard let bytes = try? JSONEncoder().encode(snapshot) else { return nil }
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("HUNT_MAP_KZ_Backup_\(Int(Date().timeIntervalSince1970)).json")
        do {
            try bytes.write(to: destination, options: .atomic)
            return destination
        } catch {
            AppDiagnosticLog.shared.recordError(subsystem: "Данные",
                operation: "Резервная копия", error: error)
            return nil
        }
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

// A single actor owns mutable crossing state. GPS and UIKit never wait synchronously.
private actor BoundaryWorker {
    private var engine = BoundaryEngine()
    private var revision = -1
    func process(_ fix: GPSFix, zones: [GeoZone], revision: Int) -> [BoundaryEvent] {
        if self.revision != revision {
            engine = BoundaryEngine()
            self.revision = revision
        }
        return engine.process(fix, zones: zones)
    }
}
