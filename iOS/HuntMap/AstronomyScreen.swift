import SwiftUI
import HuntCore

struct AstronomyScreen: View {
    let point: GeoPoint?
    @State private var day = Date()
    @State private var result: FieldAstronomy.Events?
    @State private var calculating = false
    private let zone = TimeZone(identifier:"Asia/Almaty") ?? .current
    private struct Request: Hashable {
        let lat: Double?
        let lon: Double?
        let date: Date
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            ReferencePageHeader(title:"Астрономия")
                .accessibilityIdentifier("astronomy_ready")
            Label("Расчёт без интернета · время Казахстана",systemImage:"sun.horizon")
                .font(.caption).foregroundStyle(HuntReference.muted)
            DatePicker("Дата",selection:$day,displayedComponents:.date)
                .environment(\.timeZone,zone).tint(HuntReference.green)
                .huntSurface().accessibilityIdentifier("astronomy_date")
            if let point {
                Text(String(format:"%.5f, %.5f",point.latitude,point.longitude)).font(.caption.monospacedDigit())
                if calculating { ProgressView() }
                else if let result { solar(result); lunar(result) }
            } else {
                ContentUnavailableView("Выберите координаты",systemImage:"location.slash",description:Text("Используйте GPS, угодье или точку на карте. Интернет не нужен."))
            }
            Text("Расчёт для открытого горизонта. Горы, погода и высота наблюдателя могут менять фактическое время. Лунные события приблизительные. Отсутствие события означает, что оно не происходит в выбранные сутки. Не определяет разрешённое время охоты.")
                .font(.caption).foregroundStyle(HuntReference.muted)
        }
        .task(id:Request(lat:point?.latitude,lon:point?.longitude,date:day)) {
            result=nil
            guard let point else { calculating=false;return }
            calculating=true
            let date=day, timeZone=zone
            let value=await Task.detached(priority:.userInitiated) {
                FieldAstronomy.calculate(date:date,point:point,timeZone:timeZone)
            }.value
            guard !Task.isCancelled else {return}
            result=value; calculating=false
        }
    }
    private func time(_ date:Date?)->String {
        guard let date else {return "Нет события"}
        let f=DateFormatter();f.locale=Locale(identifier:"ru_KZ");f.timeZone=zone;f.dateFormat="HH:mm"
        return f.string(from:date)
    }
    private func row(_ title:String,_ value:String,_ icon:String)->some View {
        HStack {Label(title,systemImage:icon).foregroundStyle(HuntReference.muted);Spacer();Text(value).fontWeight(.semibold).monospacedDigit()}.font(.subheadline)
    }
    private func solar(_ e:FieldAstronomy.Events)->some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Солнце").font(.headline)
            row("Начало гражданских сумерек",time(e.dawn),"sun.horizon")
            row("Восход",time(e.sunrise),"sunrise")
            row("Закат",time(e.sunset),"sunset")
            row("Конец гражданских сумерек",time(e.dusk),"moon.horizon")
            row("Световой день",String(format:"%d ч %02d мин",Int(e.daylightSeconds)/3600,Int(e.daylightSeconds)/60%60),"clock")
        }.huntSurface()
    }
    private func lunar(_ e:FieldAstronomy.Events)->some View {
        VStack(alignment:.leading,spacing:12) {
            Label(e.phase,systemImage:"moon.stars").font(.headline).foregroundStyle(HuntReference.green)
            row("Освещённость",String(format:"%.0f%%",e.illumination*100),"moon.circle")
            row("Восход Луны",time(e.moonrise),"arrow.up")
            row("Заход Луны",time(e.moonset),"arrow.down")
        }.huntSurface()
    }
}
