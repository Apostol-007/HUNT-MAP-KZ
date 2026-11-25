import SwiftUI
import PhotosUI
import UIKit
import HuntCore

@MainActor final class ObservationStore: ObservableObject {
    @Published private(set) var entries: [WildlifeObservation] = []
    @Published private(set) var error = ""
    private var readable = true
    private let url = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("observations.json")
    init() {
        if FileManager.default.fileExists(atPath:url.path) {
            do { entries=try JSONDecoder().decode([WildlifeObservation].self,from:Data(contentsOf:url)) }
            catch { readable=false;self.error="Не удалось прочитать дневник. Исходный файл сохранён." }
        }
    }
    func save(_ value:WildlifeObservation) throws {
        guard value.valid else {throw NSError(domain:"Observation",code:1,userInfo:[NSLocalizedDescriptionKey:"Проверьте вид, количество и данные наблюдения"])}
        var next=entries
        if let i=next.firstIndex(where:{$0.id==value.id}) {next[i]=value} else {next.append(value)}
        try write(next)
    }
    func delete(_ id:UUID) throws {try write(entries.filter{$0.id != id})}
    private func write(_ next:[WildlifeObservation]) throws {
        guard readable else {throw NSError(domain:"Observation",code:2,userInfo:[NSLocalizedDescriptionKey:error])}
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        try JSONEncoder().encode(next).write(to:url,options:[.atomic,.completeFileProtectionUnlessOpen])
        entries=next
    }
}
struct ObservationJournal: View {
    @ObservedObject var store:ObservationStore
    @ObservedObject var model:FieldModel
    @ObservedObject var wildlife:WildlifeStore
    let weather:PointWeather?
    let onMap:(GeoPoint)->Void
    @State private var query=""
    @State private var recentOnly=false
    @State private var editor:WildlifeObservation?
    @State private var error=""
    @State private var deleting:WildlifeObservation?
    @State private var exportURL:URL?
    @State private var includeLocations=false
    @State private var includePhotos=false
    private var filtered:[WildlifeObservation] {
        store.entries.filter { ObservationValidation.matches($0,query:query) && (!recentOnly || $0.observedAt >= Date().addingTimeInterval(-7*86400)) }.sorted{$0.observedAt>$1.observedAt}
    }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Личный дневник").font(.headline)
            Text("Записи и фотографии остаются на устройстве. Экспорт выполняется только по вашему действию.").font(.caption).foregroundStyle(HuntReference.muted)
            HuntAction(title:"Новое наблюдение",symbol:"plus",primary:true) {editor=makeEntry()}
                .accessibilityIdentifier("observation_add")
            HuntSearchField(text:$query,placeholder:"Вид, угодье, заметка")
            Toggle("Последние 7 дней",isOn:$recentOnly).font(.subheadline)
            if filtered.isEmpty {ContentUnavailableView("Нет наблюдений",systemImage:"binoculars")}
            ForEach(filtered) { item in
                VStack(alignment:.leading,spacing:8) {
                    HStack(alignment:.top) {
                        if let data=item.photoJPEG,let image=UIImage(data:data) {
                            Image(uiImage:image).resizable().scaledToFill().frame(width:60,height:60).clipped().clipShape(RoundedRectangle(cornerRadius:8))
                        }
                        VStack(alignment:.leading,spacing:4) {
                            Text(item.species).font(.headline)
                            Text(item.observedAt.formatted(date:.abbreviated,time:.shortened)+" · "+String(item.count)+" особей").font(.caption)
                            if let ground=item.groundName {Text(ground).font(.caption)}
                            if !item.notes.isEmpty {Text(item.notes).font(.caption).lineLimit(3)}
                        }
                        Spacer()
                    }
                    HStack {
                        HuntAction(title:"Изменить",symbol:"pencil") {editor=item}
                        if let point=item.point {HuntAction(title:"На карте",symbol:"map") {onMap(point)}}
                        Button(role:.destructive) {deleting=item} label:{Image(systemName:"trash").frame(width:44,height:44)}
                    }
                }.huntSurface()
            }
            if !store.entries.isEmpty {exportControls}
            if !store.error.isEmpty {Text(store.error).foregroundStyle(.orange)}
            if !error.isEmpty {Text(error).foregroundStyle(.orange)}
        }
        .sheet(item:$editor) { item in
            ObservationEditor(value:item,store:store,wildlife:wildlife).huntModal()
        }
        .confirmationDialog("Удалить наблюдение?",isPresented:Binding(get:{deleting != nil},set:{if !$0 {deleting=nil}})) {
            Button("Удалить",role:.destructive) {
                if let item=deleting {do {try store.delete(item.id)} catch {self.error=error.localizedDescription}}
                deleting=nil;exportURL=nil
            }
            Button("Отмена",role:.cancel) {deleting=nil}
        }
    }
    private var exportControls:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Экспорт выбранных записей").font(.headline)
            Toggle("Включить точные координаты и угодья",isOn:$includeLocations)
            Toggle("Включить фотографии",isOn:$includePhotos)
            Text("Свободный текст и названия видов тоже могут раскрывать местоположение. Проверьте файл перед передачей.").font(.caption).foregroundStyle(HuntReference.muted)
            HuntAction(title:"Подготовить JSON",symbol:"doc") {
                do {
                    let bytes=try ObservationValidation.export(filtered,includeLocations:includeLocations,includePhotos:includePhotos)
                    let url=FileManager.default.temporaryDirectory.appendingPathComponent("observations-"+UUID().uuidString+".json")
                    try bytes.write(to:url,options:[.atomic,.completeFileProtectionUnlessOpen]);exportURL=url
                } catch {self.error=error.localizedDescription}
            }
            if let exportURL {ShareLink(item:exportURL) {Label("Поделиться подготовленным файлом",systemImage:"square.and.arrow.up")}}
        }.huntSurface()
        .onChange(of:includeLocations) {_,_ in exportURL=nil}
        .onChange(of:includePhotos) {_,_ in exportURL=nil}
        .onChange(of:query) {_,_ in exportURL=nil}
        .onChange(of:recentOnly) {_,_ in exportURL=nil}
    }
    private func makeEntry()->WildlifeObservation {
        let now=Date()
        let fresh=model.fieldFixTime.map {now.timeIntervalSince($0)>=0 && now.timeIntervalSince($0)<30} ?? false
        let p=fresh ? model.coordinate:nil
        let ground=p.flatMap {point in model.zones.first{$0.contains(point)}}
        var snapshot:ObservationWeather?
        if let p,let weather,GeoMath.meters(p,GeoPoint(weather.latitude,weather.longitude))<10000,
           abs(now.timeIntervalSince(weather.current.timestamp))<3600,
           now.timeIntervalSince(weather.retrievedAt)<10800 {
            snapshot=ObservationWeather(retrievedAt:weather.retrievedAt,forecastAt:weather.current.timestamp,temperatureC:weather.temperatureC,windKmh:weather.current.windSpeedKmh,source:weather.source)
        }
        return WildlifeObservation(species:"",observedAt:now,point:p,accuracyMeters:p == nil ? nil:model.accuracy,
            fixAt:p == nil ? nil:model.fieldFixTime,altitudeMeters:p == nil ? nil:model.fieldAltitude,
            groundID:ground?.id,groundName:ground?.name,weather:snapshot)
    }
}
struct ObservationEditor:View {
    @State var value:WildlifeObservation
    @ObservedObject var store:ObservationStore
    @ObservedObject var wildlife:WildlifeStore
    @Environment(\.dismiss) private var dismiss
    @State private var photo:PhotosPickerItem?
    @State private var loading=false
    @State private var error=""
    private var suggestions:[String] {
        let names=Set(wildlife.packs.flatMap{$0.taxa}.map{$0.name_ru ?? $0.name_kk ?? $0.scientific_name})
        return Array(names.filter{value.species.isEmpty || $0.localizedCaseInsensitiveContains(value.species)}.sorted().prefix(12))
    }
    var body:some View {
        NavigationStack {
            Form {
                Section("Наблюдение") {
                    TextField("Название вида",text:$value.species).accessibilityIdentifier("observation_species")
                    ForEach(suggestions,id:\.self) { name in Button(name) {value.species=name} }
                    DatePicker("Дата и время",selection:$value.observedAt)
                    Stepper("Количество: \(value.count)",value:$value.count,in:1...100000)
                    TextField("Комментарий",text:$value.notes,axis:.vertical).lineLimit(3...6)
                }
                Section("Позиция при создании") {
                    if let p=value.point {
                        Text(String(format:"%.6f, %.6f",p.latitude,p.longitude))
                        if let accuracy=value.accuracyMeters {Text(String(format:"Точность ±%.0f м",accuracy))}
                        if let at=value.fixAt {Text(at.formatted(date:.abbreviated,time:.standard))}
                        if let altitude=value.altitudeMeters {Text(String(format:"Высота %.0f м",altitude))}
                        if let name=value.groundName {Text(name)}
                        Button("Удалить координаты",role:.destructive) {value.point=nil;value.accuracyMeters=nil;value.fixAt=nil;value.altitudeMeters=nil;value.groundID=nil;value.groundName=nil;value.weather=nil}
                    } else {Text("Свежий GPS-замер отсутствует")}
                }
                if let weather=value.weather {Section("Сохранённый модельный прогноз") {Text(weather.source);Text(weather.forecastAt.formatted(date:.abbreviated,time:.shortened));if let temp=weather.temperatureC {Text(String(format:"%.1f °C",temp))}}}
                Section("Фотография") {
                    if let data=value.photoJPEG,let image=UIImage(data:data) {
                        Image(uiImage:image).resizable().scaledToFit().frame(maxHeight:220)
                        Button("Удалить фотографию",role:.destructive) {value.photoJPEG=nil;photo=nil}
                    }
                    PhotosPicker(selection:$photo,matching:.images) {Label("Выбрать фото",systemImage:"photo")}
                    if loading {ProgressView()}
                }
                if !error.isEmpty {Text(error).foregroundStyle(.orange)}
            }.navigationTitle("Наблюдение").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) {Button("Отмена") {dismiss()}.accessibilityIdentifier("observation_cancel")}
                ToolbarItem(placement:.confirmationAction) {
                    Button("Сохранить") {do {try store.save(value);dismiss()} catch {self.error=error.localizedDescription}}.disabled(!value.valid || loading)
                }
            }
            .task(id:photo) {
                guard let photo else {loading=false;return}
                loading=true
                defer {if self.photo==photo {loading=false}}
                do {
                    guard let data=try await photo.loadTransferable(type:Data.self),let image=UIImage(data:data) else {throw CocoaError(.fileReadCorruptFile)}
                    guard !Task.isCancelled else {return}
                    let scale=min(1,1400/max(image.size.width,image.size.height))
                    let size=CGSize(width:image.size.width*scale,height:image.size.height*scale)
                    let format=UIGraphicsImageRendererFormat();format.scale=1
                    let rendered=UIGraphicsImageRenderer(size:size,format:format).image {_ in image.draw(in:CGRect(origin:.zero,size:size))}
                    guard let jpeg=rendered.jpegData(compressionQuality:0.75),jpeg.count<=2_000_000 else {throw CocoaError(.fileWriteOutOfSpace)}
                    value.photoJPEG=jpeg
                } catch {if !Task.isCancelled {self.error=error.localizedDescription}}
            }
        }
    }
}
struct OfflineWildlifeCatalog:View {
    @ObservedObject var store:WildlifeStore
    @State private var query=""
    private struct Entry:Identifiable {
        let pack:WildlifePack
        let taxon:WildlifeTaxon
        var id:String {pack.source+"|"+pack.ground_id+"|"+pack.generated_at+"|"+taxon.id}
    }
    private var results:[Entry] {
        var seen=Set<String>()
        return store.packs.flatMap {pack in pack.taxa.map {Entry(pack:pack,taxon:$0)}}.filter {item in
            let t=item.taxon
            return (query.isEmpty || [t.scientific_name,t.name_ru ?? "",t.name_kk ?? ""].contains{$0.localizedCaseInsensitiveContains(query)}) && seen.insert(item.id).inserted
        }
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Офлайн-справочник").font(.headline)
            HuntSearchField(text:$query,placeholder:"Название RU / KZ / Latin")
            Text("Найдено: \(results.count)").font(.caption)
            ForEach(Array(results.prefix(100))) { item in
                VStack(alignment:.leading,spacing:4) {
                    Text(item.taxon.name_ru ?? item.taxon.name_kk ?? item.taxon.scientific_name).font(.subheadline.bold())
                    Text(item.taxon.scientific_name).italic().font(.caption)
                    if let kk=item.taxon.name_kk {Text(kk).font(.caption)}
                    Text("Статус: "+item.taxon.category+" · записей: "+String(item.taxon.evidence_count)).font(.caption)
                    Text("Источник: "+item.pack.source+" · "+item.pack.generated_at).font(.caption2).foregroundStyle(HuntReference.muted)
                    if let date=item.taxon.latest_evidence_at {Text("Последняя запись: "+date).font(.caption2)}
                }.huntSurface()
            }
            if results.count>100 {Text("Уточните поиск для просмотра остальных видов.").font(.caption)}
            Text("Отсутствующие фото, описания и сведения об ареале не подменяются вымышленными данными.").font(.caption).foregroundStyle(HuntReference.muted)
        }
    }
}
