import UIKit
import SwiftUI
import UniformTypeIdentifiers
import CryptoKit
import HuntCore

private struct BackupPreferences:Codable {
    var online:Bool
    var grounds:Bool
    var markers:Bool
    var gps:Bool
    var track:Bool
    var style:String
    var windMS:Bool
    var pressureMMHG:Bool
}
private struct BackupContents {
    var field:LocalData
    var observations:[WildlifeObservation]
    var preferences:BackupPreferences
}
@MainActor private enum HuntBackup {
    static let names:Set<String>=["field.json","observations.json","settings.json"]
    static func hash(_ bytes:Data)->String {SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()}
    static func encode(_ content:BackupContents)throws->Data {
        let encoder=JSONEncoder()
        let parts=[("field.json",try encoder.encode(content.field)),("observations.json",try encoder.encode(content.observations)),("settings.json",try encoder.encode(content.preferences))]
        let envelope=BackupEnvelope(files:parts.map{BackupEnvelope.Entry(name:$0.0,bytes:$0.1,sha256:hash($0.1))})
        try envelope.validateStructure(required:names)
        return try encoder.encode(envelope)
    }
    static func decode(_ data:Data)throws->BackupContents {
        guard data.count<=205_000_000 else {throw CocoaError(.fileReadTooLarge)}
        let envelope=try JSONDecoder().decode(BackupEnvelope.self,from:data)
        try envelope.validateStructure(required:names)
        for f in envelope.files {guard hash(f.bytes)==f.sha256 else {throw CocoaError(.fileReadCorruptFile)}}
        let files=Dictionary(uniqueKeysWithValues:envelope.files.map{($0.name,$0.bytes)})
        let decoder=JSONDecoder()
        var field=try decoder.decode(LocalData.self,from:files["field.json"]!)
        let observations=try decoder.decode([WildlifeObservation].self,from:files["observations.json"]!)
        let prefs=try decoder.decode(BackupPreferences.self,from:files["settings.json"]!)
        if let pending=field.pendingTrack {
            if !pending.fixes.isEmpty && !field.tracks.contains(where:{$0.id==pending.id}) {field.tracks.append(pending)}
            field.pendingTrack=nil
        }
        guard field.markers.allSatisfy({$0.coordinate.valid}),
              field.tracks.allSatisfy({$0.fixes.allSatisfy{$0.point.valid && $0.accuracy.isFinite && $0.accuracy>=0 && $0.altitude.isFinite}}),
              observations.allSatisfy({$0.valid}),
              Set(field.markers.map(\.id)).count==field.markers.count,
              Set(field.tracks.map(\.id)).count==field.tracks.count,
              Set(field.zones.map(\.id)).count==field.zones.count,
              Set(observations.map(\.id)).count==observations.count else {throw CocoaError(.fileReadCorruptFile)}
        return BackupContents(field:field,observations:observations,preferences:prefs)
    }
    static func merge(_ local:BackupContents,_ imported:BackupContents)->BackupContents {
        var result=local
        result.field.markers=BackupMerge.records(local.field.markers,imported.field.markers,id:{$0.id})
        result.field.tracks=BackupMerge.records(local.field.tracks,imported.field.tracks,id:{$0.id})
        let deleted=local.field.deletedGroundIDs ?? []
        result.field.zones=BackupMerge.records(local.field.zones,imported.field.zones.filter{!deleted.contains($0.id)},id:{$0.id})
        result.field.groundRevisions=Array(BackupMerge.records(local.field.groundRevisions ?? [],imported.field.groundRevisions ?? [],id:{$0.id}).sorted{$0.date>$1.date}.prefix(200))
        result.observations=BackupMerge.records(local.observations,imported.observations,id:{$0.id})
        return result
    }
}
struct HuntSettingsScreen:View {
    @ObservedObject var model:FieldModel
    @ObservedObject var observations:ObservationStore
    @Binding var online:Bool
    @Binding var grounds:Bool
    @Binding var markers:Bool
    @Binding var gps:Bool
    @Binding var track:Bool
    let onStorage:()->Void
    let onDiagnostics:()->Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("hunt.map.style") private var style="protomaps"
    @AppStorage("hunt.weather.windMS") private var windMS=false
    @AppStorage("hunt.navigation.voice") private var voiceGuidance=true
    @AppStorage("hunt.weather.pressureMMHG") private var pressureMMHG=false
    @State private var importing=false
    @State private var pending:BackupContents?
    @State private var recoveryURL: URL?
    @State private var shareURL:URL?
    @State private var status=""
    @State private var showReset=false
    @State private var busy=false
    var body:some View {
        NavigationStack {
            Form {
                Section("Карта") {
                    Toggle("Онлайн-подложка",isOn:$online)
                    Toggle("Охотугодья",isOn:$grounds)
                    Toggle("Метки",isOn:$markers)
                    Toggle("GPS на карте",isOn:$gps)
                    Toggle("Треки на карте",isOn:$track)
                }
                Section("GPS и навигация") {
                    Toggle("Голосовое сопровождение маршрута", isOn: $voiceGuidance)
                    Text("На экране используется установленный русский голос iOS. В фоне — звуковые уведомления при отклонении и прибытии, если разрешены.").font(.caption)
                    Text(model.status)
                    Text(model.gpsAuthorization).font(.caption)
                    Button("Запросить GPS") {model.requestGPS()}
                    Text("Настройки разрешений, фоновой геолокации и уведомлений задаются в iOS.").font(.caption)
                    Button("Открыть настройки iOS") {
                        if let url=URL(string:UIApplication.openSettingsURLString) {UIApplication.shared.open(url)}
                    }
                }
                Section("Погода") {
                    Toggle("Ветер в м/с",isOn:$windMS)
                    Toggle("Давление в мм рт. ст.",isOn:$pressureMMHG)
                }
                Section("Хранилище и диагностика") {
                    Button("Офлайн-карты",action:onStorage)
                    Button("Диагностика",action:onDiagnostics)
                    Text("Маршрутов: \(model.tracks.count) · меток: \(model.markers.count) · наблюдений: \(observations.entries.count)").font(.caption)
                }
                backupSection
                Section("Сброс") {
                    Button("Сбросить настройки отображения",role:.destructive) {showReset=true}
                    Text("Маршруты, метки, угодья и дневник не удаляются.").font(.caption)
                }
            }
            .navigationTitle("Настройки").navigationBarTitleDisplayMode(.inline)
            .onAppear { findRecoveryCopy() }
            .toolbar {ToolbarItem(placement:.topBarTrailing) {Button("Готово"){dismiss()}}}
            .fileImporter(isPresented:$importing,allowedContentTypes:[UTType(filenameExtension:"huntbackup") ?? .data],allowsMultipleSelection:false) { result in
                do {
                    guard let url=try result.get().first else{return}
                    let access=url.startAccessingSecurityScopedResource()
                    defer {if access {url.stopAccessingSecurityScopedResource()}}
                    let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
                    guard size<=205_000_000 else {throw CocoaError(.fileReadTooLarge)}
                    pending=try HuntBackup.decode(Data(contentsOf:url))
                } catch {status="Импорт отклонён: "+error.localizedDescription}
            }
            .confirmationDialog("Восстановить резервную копию?",isPresented:Binding(get:{pending != nil},set:{if !$0 {pending=nil}}),titleVisibility:.visible) {
                Button("Объединить, сохранить локальные записи") {restore(replace:false)}
                Button("Заменить пользовательские данные",role:.destructive) {restore(replace:true)}
                Button("Отмена",role:.cancel) {pending=nil}
            } message: {Text("Перед восстановлением создаётся локальная страховочная копия. Объединение сохраняет локальные записи при совпадении ID.")}
            .confirmationDialog("Сбросить только настройки?",isPresented:$showReset) {
                Button("Сбросить",role:.destructive) {online=true;grounds=true;markers=true;gps=true;track=true;windMS=false;pressureMMHG=false;status="Настройки отображения сброшены"}
                Button("Отмена",role:.cancel) {}
            }
        }
    }
    private var backupSection:some View {
        Section("Резервное копирование") {
            Text("Файл .huntbackup содержит персональные координаты и фотографии. Не передавайте его посторонним. Карты не включаются.").font(.caption)
            Button("Создать резервную копию") {
                do {
                    try model.validateBackupTarget();try observations.validateBackupTarget()
                    let url=FileManager.default.temporaryDirectory.appendingPathComponent("HUNT-"+UUID().uuidString+".huntbackup")
                    try HuntBackup.encode(snapshot()).write(to:url,options:[.atomic,.completeFileProtectionUnlessOpen])
                    shareURL=url;status="Копия подготовлена"
                } catch {status=error.localizedDescription}
            }.accessibilityIdentifier("backup_create").disabled(busy)
            if let shareURL {ShareLink(item:shareURL){Label("Сохранить или передать копию",systemImage:"square.and.arrow.up").accessibilityIdentifier("backup_share")}}
            if let recoveryURL {ShareLink(item:recoveryURL) {Label("Последняя страховочная копия",systemImage:"clock.arrow.circlepath")}}
            Button("Восстановить из файла") {importing=true}.accessibilityIdentifier("backup_import").disabled(busy)
            if !status.isEmpty {Text(status).font(.caption).foregroundStyle(HuntReference.muted)}
        }
    }
    private func findRecoveryCopy() {
        let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Recovery",isDirectory:true)
        let files=(try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.contentModificationDateKey],options:[.skipsHiddenFiles])) ?? []
        recoveryURL=files.filter{$0.pathExtension=="huntbackup"}.max { a,b in
            let x=(try? a.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let y=(try? b.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return x<y
        }
    }
    private func snapshot()->BackupContents {
        BackupContents(field:model.backupSnapshot(),observations:observations.entries,
            preferences:BackupPreferences(online:online,grounds:grounds,markers:markers,gps:gps,track:track,style:style,windMS:windMS,pressureMMHG:pressureMMHG))
    }
    private func restore(replace:Bool) {
        guard let incoming=pending else{return}
        pending=nil;busy=true;defer{busy=false}
        do {
            try model.validateBackupTarget();try observations.validateBackupTarget()
            let previous=snapshot()
            let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Recovery",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let safety=directory.appendingPathComponent("before-"+UUID().uuidString+".huntbackup")
            try HuntBackup.encode(previous).write(to:safety,options:[.atomic,.completeFileProtectionUnlessOpen])
            shareURL=safety
            recoveryURL=safety
            let next=replace ? incoming:HuntBackup.merge(previous,incoming)
            try model.installBackupSnapshot(next.field)
            do {try observations.installBackupEntries(next.observations)}
            catch {
                do {try model.installBackupSnapshot(previous.field)}
                catch {status="Ошибка отката. Страховочная копия сохранена: "+safety.lastPathComponent;return}
                throw error
            }
            if replace {
                let p=next.preferences
                online=p.online;grounds=p.grounds;markers=p.markers;gps=p.gps;track=p.track;style=p.style;windMS=p.windMS;pressureMMHG=p.pressureMMHG
            }
            status="Восстановление завершено. Страховочная копия доступна для сохранения."
        } catch {status="Ошибка восстановления: "+error.localizedDescription}
    }
}
