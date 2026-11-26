import Foundation
import CoreLocation
import UserNotifications
import AudioToolbox
import UIKit
import HuntCore

struct Marker: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var kind: String
    var coordinate: GeoPoint
    var createdAt: Date = Date()
    // Optional styling metadata keeps older saved marker JSON compatible.
    var symbol: String? = nil
    var colorHex: String? = nil
}
struct TrackFix: Codable, Equatable {
    var point: GeoPoint
    var timestamp: Date
    var accuracy: Double
    var altitude: Double
    var verticalAccuracy: Double? = nil
    var segmentStart: Bool? = nil
    var speedMetersPerSecond: Double? = nil
}
struct Track: Identifiable, Codable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = Date()
    var fixes: [TrackFix] = [] { didSet { cachedStatistics = nil } }
    private var cachedStatistics: TrackStatistics? = nil
    private enum CodingKeys: String, CodingKey { case id, name, createdAt, fixes, sessionEnd }
    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), fixes: [TrackFix] = [], sessionEnd: Date? = nil) {
        self.id = id; self.name = name; self.createdAt = createdAt; self.fixes = fixes; self.sessionEnd = sessionEnd
    }
    private static func sample(_ fix: TrackFix) -> TrackSample {
        TrackSample(point:fix.point,time:fix.timestamp,accuracy:fix.accuracy,
            altitude:fix.verticalAccuracy.map { $0 >= 0 && $0 <= 30 } == true ? fix.altitude:nil,
            speed:fix.speedMetersPerSecond,segmentStart:fix.segmentStart ?? false)
    }
    var statistics: TrackStatistics {
        cachedStatistics ?? TrackStatistics.calculate(fixes.map(Self.sample))
    }
    mutating func cacheStatistics() { cachedStatistics = statistics }
    mutating func appendFix(_ fix: TrackFix) {
        var next = statistics
        if let previous = fixes.last { next.append(from: Self.sample(previous), to: Self.sample(fix)) }
        fixes.append(fix)
        cachedStatistics = next
    }
    var distanceMeters: Double { statistics.distance }
    var hasDiscontinuity: Bool {
        zip(fixes,fixes.dropFirst()).contains { a,b in
            b.segmentStart == true || b.timestamp.timeIntervalSince(a.timestamp) > 120
        }
    }
    var sessionEnd: Date? = nil
    func elapsed(at now:Date)->TimeInterval { max(0,(sessionEnd ?? now).timeIntervalSince(createdAt)) }
    /// Elapsed time between first and last accepted fix; does not invent time for empty tracks.
    var durationSeconds: TimeInterval {
        guard let start = fixes.first?.timestamp, let finish = fixes.last?.timestamp else { return 0 }
        return max(0, finish.timeIntervalSince(start))
    }
}
struct GroundRevision: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let groundID: String
    let previous: GeoZone?
    let action: String
}
struct LocalData: Codable {
    var markers:[Marker]=[]
    var tracks:[Track]=[]
    var pendingTrack:Track?=nil
    var zones:[GeoZone]=[]
    var groundRevisions:[GroundRevision]?=nil
    var deletedGroundIDs:Set<String>?=nil
}

@MainActor final class FieldModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var coordinate: GeoPoint?
    @Published var accuracy: Double?
    @Published private(set) var fieldFixTime: Date?
    @Published private(set) var fieldSpeed: Double?
    @Published private(set) var fieldAltitude: Double?
    @Published private(set) var fieldHeading: Double?
    @Published private(set) var fieldHeadingIsTrue = false
    @Published private(set) var fieldCourse: Double?
    @Published var markers: [Marker] = []
    @Published var tracks: [Track] = []
    @Published var currentTrack: Track?
    @Published var recording = false
    @Published private(set) var navigatingRecordedTrack = false
    @Published private(set) var recordedGuidanceResult: TrackReturnTracker.Result?
    private var recordedTracker: TrackReturnTracker?
    private lazy var navigationVoice = NavigationVoice()
    @discardableResult
    func beginRecordedGuidance(points: [GeoPoint]) -> Bool {
        guard let tracker = TrackReturnTracker(points: points) else { return false }
        recordedTracker = tracker
        recordedGuidanceResult = nil
        navigationVoice.reset()
        startRecordedRouteGuidance()
        return true
    }
    private func updateRecordedGuidance(_ fix: CLLocation, position: GeoPoint) {
        guard navigatingRecordedTrack, var tracker = recordedTracker else { return }
        guard fix.horizontalAccuracy <= 50 else { return }
        let result = tracker.update(position: position, accuracy: fix.horizontalAccuracy, timestamp: fix.timestamp)
        recordedTracker = tracker
        recordedGuidanceResult = result
        navigationVoice.update(result, timestamp: fix.timestamp)
        if result.arrived {
            recordedTracker = nil
            navigatingRecordedTrack = false
            reconcileGPS()
        }
    }
    @Published var paused = false
    @Published var status = "GPS не запущен"
    @Published var lastWarning = "Границы не загружены"
    @Published var zones: [GeoZone] = [] { didSet { groundGeometryRevision &+= 1 } }
    private(set) var groundGeometryRevision: Int = 0
    @Published private(set) var groundRevisions: [GroundRevision] = []
    private var deletedGroundIDs: Set<String> = []
    private var fieldStorageReadable = true
    @Published private(set) var startupLoaded = false
    @Published var strictOffline = true
    @Published var gpsAuthorization = "не определено"
    @Published var lastError = ""
    private let manager=CLLocationManager()
    private var foregroundGPS = true
    private var needsContinuousGPS: Bool { (recording && !paused) || navigatingRecordedTrack || monitoredGroundID != nil }
    func setForegroundGPS(_ active: Bool) {
        foregroundGPS = active
        reconcileGPS()
    }
    private func reconcileGPS() {
        let authorized = manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse
        let background = manager.authorizationStatus == .authorizedAlways && needsContinuousGPS
        manager.allowsBackgroundLocationUpdates = background
        manager.pausesLocationUpdatesAutomatically = !needsContinuousGPS
        if authorized && (foregroundGPS || background) { manager.startUpdatingLocation() }
        else { manager.stopUpdatingLocation() }
    }
    private var engine=BoundaryEngine()
    @Published private(set) var monitoredGroundID: String?
    @Published private(set) var groundMonitorStatus = "Контроль выключен"
    private var groundLastTimestamp: Date?
    private var groundWasInside = false
    private var groundOutsideCount = 0
    private var lastFix: CLLocation?
    private var newSegment = true
    @Published private(set) var recoveredSession = false
    private var documentURL:URL {
        let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
        try? FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        return dir.appendingPathComponent("field.json")
    }
    private func journalDirectory(_ id: UUID) -> URL {
        documentURL.deletingLastPathComponent().appendingPathComponent("TrackJournal", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }
    override init() {
        super.init()
        manager.delegate=self
        manager.desiredAccuracy=kCLLocationAccuracyBest
        manager.distanceFilter=5
        // Root view starts loading only after the first SwiftUI frame.
    }
    private func loadBundledGrounds() {
        guard fieldStorageReadable else { return }
        let seedKey = "hunt.grounds.seed.153.v1"
        guard !UserDefaults.standard.bool(forKey: seedKey) else { return }
        guard let url = Bundle.main.url(forResource: "HuntGrounds153", withExtension: "geojson") else {
            lastWarning = "В сборке отсутствует каталог угодий"
            return
        }
        Task { [weak self] in
            do {
                let items = try await Task.detached(priority: .utility) { try GeoJSONImport.load(url) }.value
                guard let self, items.count == 153 else { return }
                self.setImportedZones(items)
                UserDefaults.standard.set(true, forKey: seedKey)
                self.lastWarning = "Загружены 153 контура покрытия; юридические границы не подтверждены"
            } catch {
                self?.lastWarning = "Ошибка загрузки встроенных угодий: " + error.localizedDescription
            }
        }
    }

    func startFieldHeading() {
        requestGPS()
        if CLLocationManager.headingAvailable() {
            manager.headingFilter = 3
            manager.startUpdatingHeading()
        }
    }
    func stopFieldHeading() {
        manager.stopUpdatingHeading()
        fieldHeading = nil
    }
    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard heading.headingAccuracy >= 0, heading.headingAccuracy <= 45 else {
            fieldHeading = nil
            return
        }
        fieldHeadingIsTrue = heading.trueHeading >= 0
        fieldHeading = fieldHeadingIsTrue ? heading.trueHeading : heading.magneticHeading
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
        recordedTracker = nil
        recordedGuidanceResult = nil
        navigationVoice.reset()
        reconcileGPS()
    }

    func startTrack() {
        guard !recording, fieldStorageReadable else {return}
        guard CLLocationManager.locationServicesEnabled() else {
            status = "GPS выключен в настройках iPhone"; lastError = status; return
        }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else {
            status = "Дайте разрешение GPS, затем повторите запись"
            lastError = status
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            return
        }
        newSegment=true; recoveredSession=false
        lastFix=nil // Do not reuse the last fix from a previous recording session.
        let track = Track(name:"Маршрут \(Date.now.formatted(date:.numeric,time:.shortened))")
        // Commit session metadata before the first point can be accepted.
        do {
            var snapshot = backupSnapshot()
            snapshot.pendingTrack = track
            try writeSnapshot(snapshot)
        } catch {
            lastError = "Не удалось начать запись: " + error.localizedDescription
            return
        }
        currentTrack=track
        recording=true;paused=false
        // Background updates are enabled ONLY after Always authorization; foreground-only
        // recording must never terminate the app because the user denied Always access.
        if manager.authorizationStatus == .authorizedAlways {
            manager.allowsBackgroundLocationUpdates = true
            manager.pausesLocationUpdatesAutomatically = false
        }
        manager.startUpdatingLocation()
        status = manager.authorizationStatus == .authorizedAlways ? "Запись: фон разрешён" : "Запись: только на экране; для фона разрешите «Всегда»"
    }
    func togglePause() {
        guard recording, fieldStorageReadable else { return }
        paused.toggle()
        newSegment=true
        if !paused { recoveredSession=false }
        lastFix = nil // A paused interval must not create a jump when recording resumes.
        status = paused ? "Запись приостановлена" : "Запись продолжена"
        reconcileGPS()
        persist()
    }
    func stopTrack() {
        guard recording else {return}
        guard let pending = currentTrack, fieldStorageReadable else { return }
        var snapshot = backupSnapshot()
        snapshot.pendingTrack = nil
        if !pending.fixes.isEmpty {
            var finished = pending
            finished.sessionEnd = Date()
            snapshot.tracks.insert(finished, at: 0)
        }
        // Commit archive first. On failure leave the current recording recoverable.
        do { try writeSnapshot(snapshot) }
        catch {
            lastError = "Не удалось завершить запись: " + error.localizedDescription
            return
        }
        tracks = snapshot.tracks
        do { try TrackPointJournal.remove(directory: journalDirectory(pending.id)) }
        catch { lastError = "Маршрут сохранён; журнал не удалён: " + error.localizedDescription }
        recoveredSession=false;newSegment=true
        currentTrack=nil;recording=false;paused=false
        lastFix=nil
        if manager.allowsBackgroundLocationUpdates && !navigatingRecordedTrack && monitoredGroundID == nil { manager.allowsBackgroundLocationUpdates=false }
        reconcileGPS()
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
    /// Commit all generated copies together, without changing any source track.
    func saveEditedTracks(_ copies: [Track]) throws {
        guard fieldStorageReadable, !copies.isEmpty,
              copies.allSatisfy({ $0.fixes.count >= 2 && $0.fixes.allSatisfy { $0.point.valid } }),
              Set(copies.map(\.id)).count == copies.count,
              !copies.contains(where: { copy in tracks.contains(where: { $0.id == copy.id }) || currentTrack?.id == copy.id })
        else { throw CocoaError(.fileWriteUnknown) }
        var snapshot = backupSnapshot()
        snapshot.tracks.insert(contentsOf: copies, at: 0)
        try writeSnapshot(snapshot)
        tracks = snapshot.tracks
    }
    func deleteTrack(id: UUID) {
        tracks.removeAll { $0.id == id }
        persist()
    }
    func setImportedZones(_ imported:[GeoZone]) {
        let existing = Dictionary(zones.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = existing
        for ground in imported where existing[ground.id] == nil && !deletedGroundIDs.contains(ground.id) { merged[ground.id] = ground }
        zones = merged.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        lastWarning = "Импортированные границы юридически не проверены"
        persist()
    }
    func saveGround(_ ground: GeoZone) {
        do { try commitGround(ground) }
        catch { lastError = error.localizedDescription }
    }
    func deleteGround(_ id: String) {
        do { try commitGroundDeletion(id) }
        catch { lastError = error.localizedDescription }
    }
    func commitGround(_ ground: GeoZone) throws {
        var next = zones
        let previous = next.first { $0.id == ground.id }
        if let i = next.firstIndex(where: { $0.id == ground.id }) { next[i] = ground }
        else { next.append(ground) }
        var deleted = deletedGroundIDs
        deleted.remove(ground.id)
        try writeGroundChange(next, deleted: deleted, revision: GroundRevision(date: Date(), groundID: ground.id, previous: previous, action: previous == nil ? "Создание" : "Редактирование"))
    }
    func commitGroundDeletion(_ id: String) throws {
        guard let previous = zones.first(where: { $0.id == id }) else { return }
        var deleted = deletedGroundIDs
        deleted.insert(id)
        try writeGroundChange(zones.filter { $0.id != id }, deleted: deleted, revision: GroundRevision(date: Date(), groundID: id, previous: previous, action: "Удаление"))
    }
    func restoreGroundRevision(_ revision: GroundRevision) throws {
        if let previous = revision.previous { try commitGround(previous) }
        else { try commitGroundDeletion(revision.groundID) }
    }
    private func writeGroundChange(_ next: [GeoZone], deleted: Set<String>, revision: GroundRevision) throws {
        guard fieldStorageReadable else { throw CocoaError(.fileReadCorruptFile) }
        let sorted = next.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let history = Array(([revision] + groundRevisions).prefix(200))
        let data = LocalData(markers: markers, tracks: tracks, pendingTrack: currentTrack, zones: sorted,
                             groundRevisions: history, deletedGroundIDs: deleted)
        try JSONEncoder().encode(data).write(to: documentURL, options: [.atomic,.completeFileProtectionUnlessOpen])
        zones = sorted
        groundRevisions = history
        deletedGroundIDs = deleted
        if monitoredGroundID == revision.groundID {
            if deleted.contains(revision.groundID) { stopGroundMonitor() }
            else { groundWasInside = false; groundOutsideCount = 0 }
        }
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
        reconcileGPS()
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
        fieldFixTime = fix.timestamp
        fieldSpeed = fix.speed >= 0 && fix.speed.isFinite ? fix.speed * 3.6 : nil
        fieldAltitude = fix.verticalAccuracy >= 0 && fix.altitude.isFinite ? fix.altitude : nil
        fieldCourse = fix.course >= 0 && fix.course.isFinite ? fix.course : nil
        status="GPS ±\(Int(fix.horizontalAccuracy)) м"
        checkSelectedGround(fix, point: p)
        updateRecordedGuidance(fix, position: p)
        if recording && !paused && fieldStorageReadable {
            if !newSegment, let last=lastFix, fix.timestamp.timeIntervalSince(last.timestamp)<1 {return}
            if !newSegment, let last=lastFix {
                let dt=fix.timestamp.timeIntervalSince(last.timestamp)
                if dt>120 { newSegment=true }
                if !newSegment && dt>0 && GeoMath.meters(GeoPoint(last.coordinate.latitude,last.coordinate.longitude),p)/dt>80 {return}
            }
            guard let track = currentTrack else { return }
            let point = TrackFix(point:p,timestamp:fix.timestamp,accuracy:fix.horizontalAccuracy,altitude:fix.altitude.isFinite ? fix.altitude : 0,verticalAccuracy:fix.altitude.isFinite ? fix.verticalAccuracy : nil,segmentStart:newSegment,speedMetersPerSecond:fix.speed.isFinite && fix.speed >= 0 ? fix.speed:nil)
            do {
                try TrackPointJournal.append(point, index: track.fixes.count, directory: journalDirectory(track.id))
            } catch {
                lastError = "Ошибка записи GPS-точки: " + error.localizedDescription
                paused = true
                newSegment = true
                reconcileGPS()
                return
            }
            currentTrack?.appendFix(point)
            newSegment=false
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
            notification.title="QAZ TRAIL";notification.body=message;notification.sound = .default
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
        reconcileGPS()
        gpsAuthorization = String(describing: manager.authorizationStatus.rawValue)
        if manager.authorizationStatus == .denied {status="Нет разрешения геолокации"; lastError=status}
    }
    func backupSnapshot() -> LocalData {
        LocalData(markers:markers,tracks:tracks,pendingTrack:currentTrack,zones:zones,
                  groundRevisions:groundRevisions,deletedGroundIDs:deletedGroundIDs)
    }
    func validateBackupTarget() throws {
        if recording || currentTrack != nil || navigatingRecordedTrack || monitoredGroundID != nil {
            throw NSError(domain:"HuntBackup",code:1,userInfo:[NSLocalizedDescriptionKey:"Завершите запись, навигацию и контроль границ перед восстановлением"])
        }
        if FileManager.default.fileExists(atPath:documentURL.path) {
            _ = try JSONDecoder().decode(LocalData.self,from:Data(contentsOf:documentURL))
        }
    }
    func installBackupSnapshot(_ data: LocalData) throws {
        try validateBackupTarget()
        let encoded=try JSONEncoder().encode(data)
        try encoded.write(to:documentURL,options:[.atomic,.completeFileProtectionUnlessOpen])
        markers=data.markers;tracks=data.tracks.map { track in var item = track; item.cacheStatistics(); return item };zones=data.zones
        groundRevisions=data.groundRevisions ?? [];deletedGroundIDs=data.deletedGroundIDs ?? []
    }
    /// Decode and rebuild track caches away from the UI thread. Do not expose
    /// editing controls until the existing snapshot and journal are restored.
    func loadAtStartup() async {
        guard !startupLoaded else { return }
        let url = documentURL
        defer { startupLoaded = true; loadBundledGrounds() }
        do {
            let result = try await Task.detached(priority: .utility) { () -> (LocalData?, Bool, String?) in
                guard FileManager.default.fileExists(atPath: url.path) else { return (nil, false, nil) }
                var obj = try JSONDecoder().decode(LocalData.self, from: Data(contentsOf: url, options: .mappedIfSafe))
                for i in obj.tracks.indices { obj.tracks[i].cacheStatistics() }
                var warning: String?
                if var pending = obj.pendingTrack {
                    if obj.tracks.contains(where: { $0.id == pending.id }) {
                        obj.pendingTrack = nil
                    } else {
                        let directory = url.deletingLastPathComponent().appendingPathComponent("TrackJournal", isDirectory: true)
                            .appendingPathComponent(pending.id.uuidString, isDirectory: true)
                        do {
                            let extra = try TrackPointJournal.recover(TrackFix.self, after: pending.fixes.count, directory: directory)
                            pending.fixes.append(contentsOf: extra)
                        } catch { warning = error.localizedDescription }
                        pending.cacheStatistics()
                        obj.pendingTrack = pending
                    }
                }
                return (obj, obj.pendingTrack != nil, warning)
            }.value
            guard let obj = result.0 else { return }
            markers = obj.markers; tracks = obj.tracks; zones = obj.zones
            groundRevisions = obj.groundRevisions ?? []
            deletedGroundIDs = obj.deletedGroundIDs ?? []
            if let warning = result.2 {
                fieldStorageReadable = false
                lastError = "Журнал маршрута повреждён; исходные файлы сохранены: " + warning
            }
            if result.1, let pending = obj.pendingTrack {
                currentTrack = pending; recording = true; paused = true
                recoveredSession = true; newSegment = true
                lastWarning = "Незавершённая запись восстановлена на паузе."
            }
        } catch {
            fieldStorageReadable = false
            lastError = "Не удалось прочитать field.json. Исходный файл защищён от перезаписи."
        }
    }
    private func writeSnapshot(_ data: LocalData) throws {
        guard fieldStorageReadable else { throw CocoaError(.fileReadCorruptFile) }
        try JSONEncoder().encode(data).write(to:documentURL, options:[.atomic,.completeFileProtectionUnlessOpen])
    }
    private func persist() {
        guard fieldStorageReadable else { return }
        do { try writeSnapshot(backupSnapshot()) }
        catch { lastError = "Ошибка сохранения полевых данных: " + error.localizedDescription }
    }
    func exportGPX(_ track:Track)->URL? {
        func xml(_ s:String)->String {s.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;")}
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var segmentIndex = 0
        let points = track.fixes.enumerated().map { index, fix -> String in
            let elevation = fix.altitude.isFinite && fix.verticalAccuracy.map({$0 >= 0 && $0 <= 30}) == true ? "<ele>\(fix.altitude)</ele>" : ""
            let split = index > 0 && (fix.segmentStart == true || fix.timestamp.timeIntervalSince(track.fixes[index-1].timestamp)>120)
            if split { segmentIndex += 1 }
            return (split ? "</trkseg><trkseg>" : "") + "<trkpt lat=\"\(fix.point.latitude)\" lon=\"\(fix.point.longitude)\">\(elevation)<time>\(formatter.string(from:fix.timestamp))</time></trkpt>"
        }.joined()
        let data="<?xml version=\"1.0\" encoding=\"UTF-8\"?><gpx version=\"1.1\" creator=\"QAZ TRAIL\" xmlns=\"http://www.topografix.com/GPX/1/1\"><trk><name>\(xml(track.name))</name><trkseg>\(points)</trkseg></trk></gpx>"
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("route-\(track.id).gpx")
        do {try data.write(to:url,atomically:true,encoding:.utf8);return url} catch {return nil}
    }
}
