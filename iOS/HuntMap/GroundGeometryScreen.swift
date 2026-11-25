import SwiftUI
import HuntCore

struct GroundGeometryScreen: View {
    @Binding var geometry: [[[GeoPoint]]]
    let initialCenter: GeoPoint?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: [[[GeoPoint]]] = []
    @State private var polygon = 0
    @State private var ring = 0
    @State private var vertex: Int?
    @State private var undo: [[[[GeoPoint]]]] = []
    @State private var redo: [[[[GeoPoint]]]] = []
    @State private var error = ""
    @State private var latitude = ""
    @State private var longitude = ""
    @State private var center: GeoPoint?
    @State private var span = 0.01
    @State private var loaded = false

    private var vertices: [GeoPoint] {
        guard draft.indices.contains(polygon), draft[polygon].indices.contains(ring) else { return [] }
        return draft[polygon][ring]
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    Text("Локальный контур · не юридическая граница").font(.caption).foregroundStyle(.orange)
                    selection
                    if let center {
                        canvas(center).frame(height:300)
                        HStack {
                            HuntAction(title:"Приблизить",symbol:"plus.magnifyingglass") { span=max(0.00005,span/2) }
                            HuntAction(title:"Отдалить",symbol:"minus.magnifyingglass") { span=min(20,span*2) }
                            HuntAction(title:"Весь контур",symbol:"scope") { fit() }
                        }
                    } else {
                        Text("Введите координаты первой вершины или получите GPS.").font(.caption)
                    }
                    Text("Схема координат без подложки карты. Выберите вершину, затем коснитесь нового места; без выбора добавляется вершина.")
                        .font(.caption).foregroundStyle(HuntReference.muted)
                    vertexControls
                    coordinateControls
                    HStack {
                        HuntAction(title:"Отменить",symbol:"arrow.uturn.backward") { stepUndo() }.disabled(undo.isEmpty)
                        HuntAction(title:"Повторить",symbol:"arrow.uturn.forward") { stepRedo() }.disabled(redo.isEmpty)
                    }
                    if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(.horizontal,18).padding(.vertical,14)
            }.background(HuntReference.background.ignoresSafeArea())
            .navigationTitle("Контур угодья").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement:.cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement:.confirmationAction) { Button("Применить") { apply() } }
            }
        }.onAppear {
            guard !loaded else { return }
            loaded=true; draft=geometry
            if draft.isEmpty { draft=[[[]]] }
            fit()
        }
    }
    private var selection: some View {
        VStack(alignment:.leading,spacing:8) {
            Picker("Полигон",selection:$polygon) {
                ForEach(draft.indices,id:\.self) { i in Text("Полигон \(i+1)").tag(i) }
            }.onChange(of:polygon) { _,_ in ring=0; vertex=nil }
            Picker("Контур",selection:$ring) {
                if draft.indices.contains(polygon) {
                    ForEach(draft[polygon].indices,id:\.self) { i in
                        Text(i == 0 ? "Внешний" : "Исключение \(i)").tag(i)
                    }
                }
            }.onChange(of:ring) { _,_ in vertex=nil }
            HStack {
                HuntAction(title:"Полигон",symbol:"plus") {
                    checkpoint(); draft.append([[]]); polygon=draft.count-1; ring=0; vertex=nil
                }
                HuntAction(title:"Исключение",symbol:"plus") {
                    guard draft.indices.contains(polygon) else { return }
                    checkpoint(); draft[polygon].append([]); ring=draft[polygon].count-1; vertex=nil
                }
            }
            Button("Удалить выбранный контур",role:.destructive) {
                guard draft.indices.contains(polygon), draft[polygon].indices.contains(ring) else { return }
                checkpoint()
                if ring==0 { draft.remove(at:polygon); if draft.isEmpty { draft=[[[]]] }; polygon=0 }
                else { draft[polygon].remove(at:ring) }
                ring=0;vertex=nil
            }.font(.caption)
        }.huntSurface()
    }
    private func canvas(_ c:GeoPoint)->some View {
        GeometryReader { proxy in
            let size=proxy.size
            Canvas { ctx, s in
                for (pi,rings) in draft.enumerated() {
                    for (ri,points) in rings.enumerated() where !points.isEmpty {
                        let selected = pi==polygon && ri==ring
                        var path=Path()
                        path.move(to:screen(points[0],center:c,size:s))
                        for p in points.dropFirst() { path.addLine(to:screen(p,center:c,size:s)) }
                        if points.count>=3 { path.closeSubpath() }
                        ctx.stroke(path,with:.color(selected ? HuntReference.green : .gray),lineWidth:selected ? 2 : 1)
                        if selected {
                            for (i,p) in points.enumerated() {
                                let xy=screen(p,center:c,size:s)
                                let radius:CGFloat = vertex==i ? 6 : 3
                                let rect=CGRect(x:xy.x-radius,y:xy.y-radius,width:radius*2,height:radius*2)
                                ctx.fill(Path(ellipseIn:rect),with:.color(vertex==i ? .white : HuntReference.green))
                            }
                        }
                    }
                }
            }.background(HuntReference.card,in:RoundedRectangle(cornerRadius:18))
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { event in
                    let p=geographic(event.location,center:c,size:size)
                    guard p.valid else { return }
                    if vertex==nil, let hit=vertices.indices.min(by:{ distance(screen(vertices[$0],center:c,size:size),event.location)<distance(screen(vertices[$1],center:c,size:size),event.location) }),
                       distance(screen(vertices[hit],center:c,size:size),event.location)<16 {
                        select(hit)
                    } else { put(p) }
                })
        }.clipped()
    }
    private func screen(_ p:GeoPoint,center:GeoPoint,size:CGSize)->CGPoint {
        let scale=Double(min(size.width,size.height))/span
        let k=max(0.1,cos(center.latitude * .pi/180))
        return CGPoint(x:Double(size.width)/2+(p.longitude-center.longitude)*k*scale,y:Double(size.height)/2-(p.latitude-center.latitude)*scale)
    }
    private func geographic(_ p:CGPoint,center:GeoPoint,size:CGSize)->GeoPoint {
        let scale=max(1,Double(min(size.width,size.height))/span)
        let k=max(0.1,cos(center.latitude * .pi/180))
        return GeoPoint(center.latitude-(Double(p.y)-Double(size.height)/2)/scale,center.longitude+(Double(p.x)-Double(size.width)/2)/(scale*k))
    }
    private func distance(_ a:CGPoint,_ b:CGPoint)->CGFloat { hypot(a.x-b.x,a.y-b.y) }
    private var vertexControls: some View {
        VStack(alignment:.leading,spacing:8) {
            Text("Вершины: \(vertices.count)").font(.subheadline.bold())
            Menu {
                ForEach(vertices.indices,id:\.self) { i in Button("Вершина \(i+1)") { select(i) } }
            } label: { Label(vertex.map{"Вершина \($0+1)"} ?? "Выбрать вершину",systemImage:"point.topleft.down.curvedto.point.bottomright.up").frame(minHeight:44) }
            HStack {
                HuntAction(title:"Новая точка",symbol:"plus") { vertex=nil; latitude="";longitude="" }
                HuntAction(title:"Удалить точку",symbol:"minus.circle") {
                    guard let vertex,vertices.indices.contains(vertex) else { return }
                    checkpoint();draft[polygon][ring].remove(at:vertex);self.vertex=nil
                }.disabled(vertex==nil)
            }
            if let vertex, vertices.indices.contains(vertex) {
                HuntAction(title:"Вставить после вершины",symbol:"plus.circle") {
                    let a=vertices[vertex],b=vertices[(vertex+1)%vertices.count]
                    checkpoint()
                    draft[polygon][ring].insert(GeoPoint((a.latitude+b.latitude)/2,(a.longitude+b.longitude)/2),at:vertex+1)
                    select(vertex+1)
                }
            }
        }.huntSurface()
    }
    private var coordinateControls: some View {
        VStack(alignment:.leading,spacing:8) {
            TextField("Широта",text:$latitude).keyboardType(.numbersAndPunctuation)
            TextField("Долгота",text:$longitude).keyboardType(.numbersAndPunctuation)
            HuntAction(title:"Применить координаты",symbol:"checkmark") {
                guard let a=Double(latitude.replacingOccurrences(of:",",with:".")),let b=Double(longitude.replacingOccurrences(of:",",with:".")),GeoPoint(a,b).valid else {
                    error="Некорректные координаты";return
                }
                put(GeoPoint(a,b))
            }
        }.huntSurface()
    }
    private func select(_ i:Int) {
        guard vertices.indices.contains(i) else { return }
        vertex=i
        latitude=String(format:"%.8f",vertices[i].latitude)
        longitude=String(format:"%.8f",vertices[i].longitude)
    }
    private func put(_ point:GeoPoint) {
        guard draft.indices.contains(polygon),draft[polygon].indices.contains(ring),point.valid else { return }
        checkpoint()
        if let vertex,vertices.indices.contains(vertex) { draft[polygon][ring][vertex]=point }
        else { draft[polygon][ring].append(point) }
        if center==nil { center=point }
        vertex=nil;latitude="";longitude="";error=""
    }
    private func fit() {
        let points=draft.flatMap{$0.flatMap{$0}}
        guard let south=points.map(\.latitude).min(),let north=points.map(\.latitude).max(),
              let west=points.map(\.longitude).min(),let east=points.map(\.longitude).max() else {
            center=initialCenter;span=0.01;return
        }
        center=GeoPoint((south+north)/2,(west+east)/2)
        span=max(0.0001,max(north-south,(east-west)*cos((south+north)/2 * .pi/180))*1.3)
    }
    private func checkpoint() { undo.append(draft); if undo.count>30 { undo.removeFirst() };redo=[] }
    private func stepUndo() {
        guard let previous=undo.popLast() else { return }
        redo.append(draft);draft=previous;polygon=0;ring=0;vertex=nil
    }
    private func stepRedo() {
        guard let next=redo.popLast() else { return }
        undo.append(draft);draft=next;polygon=0;ring=0;vertex=nil
    }
    private func apply() {
        do { try GroundGeometryValidation.validate(draft);geometry=draft;dismiss() }
        catch { self.error=error.localizedDescription }
    }
}

struct GroundHistoryScreen: View {
    @ObservedObject var model: FieldModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: GroundRevision?
    @State private var error=""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    if model.groundRevisions.isEmpty { Text("История пока пуста").foregroundStyle(HuntReference.muted) }
                    ForEach(model.groundRevisions) { item in
                        VStack(alignment:.leading,spacing:8) {
                            Text(item.previous?.name ?? item.groundID).font(.headline)
                            Text(item.action+" · "+item.date.formatted(date:.numeric,time:.shortened)).font(.caption)
                            HuntAction(title:"Отменить эту правку",symbol:"clock.arrow.circlepath") { selected=item }
                        }.huntSurface()
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(.orange) }
                }.padding(.horizontal,18).padding(.vertical,14)
            }.background(HuntReference.background.ignoresSafeArea())
            .navigationTitle("История угодий").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button("Готово") { dismiss() } } }
            .confirmationDialog("Восстановить состояние до этой правки?",isPresented:Binding(get:{selected != nil},set:{if !$0 {selected=nil}})) {
                Button("Восстановить",role:.destructive) {
                    if let item=selected {
                        do {try model.restoreGroundRevision(item)}
                        catch {self.error=error.localizedDescription}
                    }
                    selected=nil
                }
                Button("Отмена",role:.cancel) {selected=nil}
            }
        }
    }
}
