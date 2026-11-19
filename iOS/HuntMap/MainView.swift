import SwiftUI
import HuntCore
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var model:FieldModel
    @StateObject private var tileStore = OfflineTileStore()
    @StateObject private var wildlifeStore = WildlifeStore()
    @StateObject private var wildlifeUpdater = WildlifeUpdater()
    @State private var wildlifeServer = "https://example.org"
    @State private var wildlifeGround = ""
    @State private var wildlifeImportShown = false
    @State private var wildlifeSearch = ""
    @State private var selectedScope = "ground"
    @State private var scopeID = ""
    @State private var tileImportShown=false
    @State private var importShown=false
    @State private var importError:String?
    var body:some View {
        TabView {
            mapTab.tabItem {Label("Карта",systemImage:"map")}
            tracksTab.tabItem {Label("Маршруты",systemImage:"figure.hiking")}
            markersTab.tabItem {Label("Маркеры",systemImage:"mappin.and.ellipse")}
            wildlifeTab.tabItem {Label("Животные",systemImage:"pawprint")}
            downloadsTab.tabItem {Label("Загрузки",systemImage:"arrow.down.circle")}
        }.tint(.orange)
    }
    private var mapTab:some View {
        NavigationStack {
            VStack(spacing:12) {
                HStack {Image(systemName:"location.fill").foregroundStyle(.orange);Text(model.status);Spacer();Text("OFFLINE").font(.caption.bold()).foregroundStyle(.green)}.font(.subheadline)
                Group {
                    if tileStore.installed.isEmpty {
                        OfflineCanvas(zones:model.zones,position:model.coordinate,markers:model.markers,track:model.currentTrack)
                    } else {
                        OfflineMapView(zones:model.zones,position:model.coordinate,markers:model.markers,track:model.currentTrack,tileFiles:tileStore.paths,tileRevision:tileStore.revision)
                    }
                }
                    .frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(red:0.08,green:0.13,blue:0.16)).clipShape(RoundedRectangle(cornerRadius:16))
                Text(tileStore.installed.isEmpty ? "НЕТ ОФЛАЙН-ПОДЛОЖКИ · геометрия без картографической основы" : "ОФЛАЙН-ПАКЕТОВ: \(tileStore.installed.count) · данные требуют проверки лицензий").font(.caption).foregroundStyle(.secondary)
                Text(model.lastWarning).font(.footnote).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.leading)
                HStack {
                    Button("GPS",systemImage:"location") {model.requestGPS()}.buttonStyle(.borderedProminent)
                    Button("Метка",systemImage:"mappin") {model.addMarker()}.buttonStyle(.bordered)
                    if model.recording {Button("Стоп",systemImage:"stop.fill") {model.stopTrack()}.tint(.red).buttonStyle(.borderedProminent)}
                    else {Button("Запись",systemImage:"record.circle") {model.startTrack()}.buttonStyle(.borderedProminent)}
                }.labelStyle(.titleAndIcon)
            }.padding().navigationTitle("HUNT MAP KZ")
        }
    }
    private var tracksTab:some View {
        NavigationStack {
            List {
                if let current=model.currentTrack {Section("Активный маршрут") {trackRow(current);Button(model.paused ? "Продолжить":"Пауза") {model.togglePause()}}}
                Section("История") {ForEach(model.tracks) {trackRow($0)}}
            }.overlay {if model.tracks.isEmpty && model.currentTrack == nil {ContentUnavailableView("Маршрутов пока нет",systemImage:"figure.hiking",description:Text("Начните запись на вкладке Карта"))}}.navigationTitle("Маршруты")
        }
    }
    private func trackRow(_ track:Track)->some View {
        HStack {VStack(alignment:.leading){Text(track.name);Text("\(track.fixes.count) точек · \(Int(track.distanceMeters)) м").font(.caption).foregroundStyle(.secondary)};Spacer();if let url=model.exportGPX(track) {ShareLink(item:url){Image(systemName:"square.and.arrow.up")}}}
    }
    private var markersTab:some View {
        NavigationStack {
            List {ForEach(model.markers) {m in HStack {Image(systemName:"mappin.circle.fill").foregroundStyle(.orange);VStack(alignment:.leading){Text(m.title);Text("\(m.coordinate.latitude.formatted(.number.precision(.fractionLength(5)))), \(m.coordinate.longitude.formatted(.number.precision(.fractionLength(5))))").font(.caption).foregroundStyle(.secondary)};Spacer();ShareLink(item:"geo:\(m.coordinate.latitude),\(m.coordinate.longitude)"){Image(systemName:"square.and.arrow.up")}}}.onDelete(perform:model.removeMarkers)}
            .toolbar {Button("Добавить",systemImage:"plus") {model.addMarker()}}
            .overlay {if model.markers.isEmpty {ContentUnavailableView("Маркеров пока нет",systemImage:"mappin",description:Text("Добавьте метку по GPS"))}}.navigationTitle("Маркеры")
        }
    }
    private var wildlifeTab:some View {
        NavigationStack {
            List {
                Section {
                    Text("Данные о животных не означают разрешение на охоту. Источники импортированных пакетов не проверяются приложением автоматически.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Импортировать каталог JSON", systemImage: "square.and.arrow.down") {
                        wildlifeImportShown = true
                    }
                    Text(wildlifeStore.message).font(.caption).foregroundStyle(.secondary)
                    TextField("HTTPS-адрес сервера", text: $wildlifeServer)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("ID угодья из проверенного источника", text: $wildlifeGround)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Проверить обновления", systemImage: "arrow.clockwise") {
                        Task { await wildlifeUpdater.check(server: wildlifeServer, groundID: wildlifeGround) }
                    }.disabled(wildlifeUpdater.busy)
                    Text(wildlifeUpdater.status).font(.caption).foregroundStyle(.secondary)
                    ForEach(wildlifeUpdater.candidates) { item in
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Версия: \(item.pack_id)").font(.subheadline)
                                Text("\(item.taxa_count) видов · \(item.generated_at)")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Скачать") {
                                Task { await wildlifeUpdater.install(item, server: wildlifeServer, store: wildlifeStore) }
                            }.disabled(wildlifeUpdater.busy)
                        }
                    }
                }
                ForEach(Array(wildlifeStore.packs.enumerated()), id: \.offset) { index, pack in
                    Section {
                        HStack {
                            VStack(alignment: .leading) {
                                Text("Территория: \(pack.ground_id)").font(.headline)
                                Text("Источник: \(pack.source) · \(pack.license)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text("Дата набора: \(pack.generated_at)").font(.caption2)
                            }
                            Spacer()
                            Button(role: .destructive) { wildlifeStore.remove(at: index) } label: {
                                Image(systemName: "trash")
                            }
                        }
                    } header: { Text("Каталог \(index + 1)") }
                    Section("Виды · \(pack.taxa.count)") {
                        ForEach(pack.taxa.filter { wildlifeSearch.isEmpty ||
                            $0.scientific_name.localizedCaseInsensitiveContains(wildlifeSearch) ||
                            ($0.name_ru?.localizedCaseInsensitiveContains(wildlifeSearch) ?? false) ||
                            ($0.name_kk?.localizedCaseInsensitiveContains(wildlifeSearch) ?? false)
                        }) { taxon in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(taxon.name_ru ?? taxon.name_kk ?? taxon.scientific_name).font(.headline)
                                Text(taxon.scientific_name).italic().font(.caption)
                                Text("Статус: \(wildlifeLabel(taxon.category)) · свидетельств: \(taxon.evidence_count)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let date = taxon.latest_evidence_at { Text("Последнее свидетельство: \(date)").font(.caption2) }
                                if let source = taxon.source_record_url, let url = URL(string: source) {
                                    Link("Исходная запись", destination: url).font(.caption)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $wildlifeSearch, prompt: "Русское, казахское или научное название")
            .navigationTitle("Животные")
            .fileImporter(isPresented: $wildlifeImportShown, allowedContentTypes: [.json]) { result in
                switch result {
                case .success(let url): wildlifeStore.importFile(url)
                case .failure(let error): wildlifeStore.message = error.localizedDescription
                }
            }
        }
    }
    private func wildlifeLabel(_ category: String) -> String {
        switch category {
        case "confirmed": "подтверждено источником"
        case "probable": "вероятно"
        case "historical": "историческое"
        default: "нет данных"
        }
    }
    private var downloadsTab:some View {
        NavigationStack {
            Form {
                Section("Сервер карт") {
                    TextField("https://maps.example.kz", text: $tileStore.serviceURL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("Только HTTPS. В публичном каталоге нет проверенных охотугодий: сервер должен быть настроен и наполнен правомерными данными.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Режим загрузки") {
                    Picker("Масштаб пакета", selection: $selectedScope) {
                        Text("Область").tag("region")
                        Text("Охотугодье").tag("ground")
                        Text("Казахстан").tag("country")
                    }.pickerStyle(.segmented)
                    TextField(selectedScope == "country" ? "KZ" : "ID области / угодья", text: $scopeID)
                        .textInputAutocapitalization(.never)
                    Button("Найти пакеты") {
                        Task { await tileStore.fetch(scope: selectedScope, id: selectedScope == "country" ? "KZ" : scopeID) }
                    }.disabled(tileStore.busy || (selectedScope != "country" && scopeID.isEmpty))
                    ForEach(tileStore.available) { pack in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(pack.pack_id).font(.headline)
                            Text("\(ByteCountFormatter.string(fromByteCount: pack.size_bytes, countStyle: .file)) · \(pack.source_version) · \(pack.license)")
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Скачать / продолжить (SHA-256)") { Task { await tileStore.install(pack) } }
                                .disabled(tileStore.busy)
                        }
                    }
                }
                Section("Импорт без сервера") {
                    Button("Импортировать растровый MBTiles", systemImage: "square.and.arrow.down") { tileImportShown = true }
                    Text("Только ваши файлы, которые законно разрешено копировать. Лицензия и границы автоматически не подтверждаются.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Установленные карты") {
                    if tileStore.installed.isEmpty { Text("Офлайн-карты пока отсутствуют") }
                    ForEach(tileStore.installed) { pack in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(pack.pack_id)
                                Text("\(pack.license) · \(pack.verified ? "источник проверен" : "источник не подтверждён")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(role: .destructive) { tileStore.remove(pack) } label: { Image(systemName: "trash") }
                        }
                    }
                }
                Section("Статус") {
                    if tileStore.busy { ProgressView(value: tileStore.progress) }
                    Text(tileStore.message)
                    LabeledContent("Картографических пакетов", value: String(tileStore.installed.count))
                    LabeledContent("Границ", value: String(model.zones.count))
                    LabeledContent("Каталогов животных", value: String(wildlifeStore.packs.count))
                }
                Section("Локальный GeoJSON") {Button("Импортировать границы GeoJSON",systemImage:"square.and.arrow.down") {importShown=true};if let importError {Text(importError).foregroundStyle(.red)}}
                Section("Тестирование") {Button("Показать демо-полигон") {model.loadDemoZones()};Text("Демонстрационный полигон создан искусственно. Он не является охотугодьем.").font(.caption).foregroundStyle(.secondary)}
                Section("Ограничения") {
                    Text("MapLibre использует локальный стиль без интернет-источников и файлы MBTiles. Отсутствие сетевых запросов необходимо подтвердить сетевым тестом на физическом iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Загрузки").fileImporter(isPresented: $tileImportShown, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): Task { await tileStore.importLocal(url) }
                case .failure(let error): importError = error.localizedDescription
                }
            }.fileImporter(isPresented:$importShown,allowedContentTypes:[.json]) { result in
                do {model.setImportedZones(try GeoJSONImport.load(result.get()));importError=nil} catch {importError=error.localizedDescription}
            }
        }
    }
}

struct OfflineCanvas:View {
    let zones:[GeoZone];let position:GeoPoint?;let markers:[Marker];let track:Track?
    @State private var scale=1.0
    @State private var offset:CGSize = .zero
    var body:some View {
        GeometryReader { geo in
            Canvas {context,size in
                let center=position ?? GeoPoint(43.26,76.90)
                let span=0.12/scale
                func screen(_ p:GeoPoint)->CGPoint {
                    CGPoint(x:size.width/2+(p.longitude-center.longitude)/span*size.width+offset.width,y:size.height/2-(p.latitude-center.latitude)/span*size.height+offset.height)
                }
                for zone in zones {
                    for poly in zone.polygons {
                        for ring in poly.rings {
                            guard let first=ring.first else {continue}
                            var path=Path();path.move(to:screen(first))
                            for p in ring.dropFirst() {path.addLine(to:screen(p))};path.closeSubpath()
                            context.stroke(path,with:.color(zone.verified ? .orange : .yellow),lineWidth:3)
                        }
                    }
                }
                if let track,let first=track.fixes.first {var path=Path();path.move(to:screen(first.point));for fix in track.fixes.dropFirst() {path.addLine(to:screen(fix.point))};context.stroke(path,with:.color(.green),lineWidth:3)}
                for m in markers {let p=screen(m.coordinate);context.fill(Path(ellipseIn:CGRect(x:p.x-5,y:p.y-5,width:10,height:10)),with:.color(.orange))}
                if let position {let p=screen(position);context.fill(Path(ellipseIn:CGRect(x:p.x-7,y:p.y-7,width:14,height:14)),with:.color(.blue));context.stroke(Path(ellipseIn:CGRect(x:p.x-8,y:p.y-8,width:16,height:16)),with:.color(.white),lineWidth:2)}
            }
            .overlay(alignment:.topLeading) {VStack(alignment:.leading){Text("СХЕМА · БЕЗ ПОДЛОЖКИ").font(.caption.bold());Text("Не навигационная топокарта").font(.caption2)}.foregroundStyle(.white).padding(10).background(.black.opacity(0.6)).clipShape(RoundedRectangle(cornerRadius:8)).padding(10)}
            .overlay(alignment:.bottomTrailing) {VStack {Button {scale=min(20,scale*1.5)} label:{Image(systemName:"plus")};Button {scale=max(0.5,scale/1.5)} label:{Image(systemName:"minus")}}.buttonStyle(.borderedProminent).padding(12)}
            .gesture(DragGesture().onChanged {offset=$0.translation}.onEnded {_ in offset = .zero})
        }
    }
}
