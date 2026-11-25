import SwiftUI
import UIKit
import HuntCore
import CoreLocation

@MainActor final class AdaptiveIconManager: ObservableObject {
    @AppStorage("adaptiveIcon.mode") var mode = "original"
    @AppStorage("adaptiveIcon.manual") var manual = "Original"
    @AppStorage("adaptiveIcon.holidays") var holidays = true
    @AppStorage("adaptiveIcon.weather") var weather = true
    @AppStorage("adaptiveIcon.daytime") var daytime = true
    @AppStorage("adaptiveIcon.seasons") var seasons = true
    @AppStorage("adaptiveIcon.eidDates") var eidDates = "2026-05-27"
    @AppStorage("adaptiveIcon.lastChange") private var lastChange = 0.0
    @Published private(set) var actual = "Original"
    @Published private(set) var reason = ""
    @Published private(set) var error = ""
    private var busy = false
    private var attempted: String?
    private var pending: String?
    private var pendingSince = Date.distantPast
    private var forecast: PointWeather?
    private var coordinate: GeoPoint?
    struct Entry: Identifiable { let id: String; let label: String }
    static let entries: [Entry] = [
        .init(id: "Original", label: "Оригинальная"),
        .init(id: "Classic", label: "Основная (концепт)"),
        .init(id: "Spring", label: "Весна"),
        .init(id: "Summer", label: "Лето"),
        .init(id: "Autumn", label: "Осень"),
        .init(id: "Winter", label: "Зима"),
        .init(id: "Sunny", label: "Солнечно"),
        .init(id: "Cloudy", label: "Облачно"),
        .init(id: "Rain", label: "Дождь"),
        .init(id: "Thunderstorm", label: "Гроза"),
        .init(id: "Snow", label: "Снегопад"),
        .init(id: "Fog", label: "Туман"),
        .init(id: "Wind", label: "Сильный ветер"),
        .init(id: "Night", label: "Ночь"),
        .init(id: "Sunrise", label: "Рассвет"),
        .init(id: "Sunset", label: "Закат"),
        .init(id: "NewYear", label: "Новый год"),
        .init(id: "Christmas", label: "Рождество"),
        .init(id: "Nauryz", label: "Наурыз"),
        .init(id: "Independence", label: "День независимости"),
        .init(id: "Hunting", label: "Охотничья тематика"),
        .init(id: "Women", label: "8 марта"),
        .init(id: "Constitution", label: "День Конституции"),
        .init(id: "Unity", label: "День единства"),
        .init(id: "Defender", label: "День защитника"),
        .init(id: "Victory", label: "День Победы"),
        .init(id: "Eid", label: "Курбан айт"),
        .init(id: "Capital", label: "День столицы"),
        .init(id: "Republic", label: "День Республики"),
        .init(id: "SpringNight", label: "Весенняя ночь"),
        .init(id: "SummerNight", label: "Летняя ночь"),
        .init(id: "AutumnNight", label: "Осенняя ночь"),
        .init(id: "WinterNight", label: "Зимняя ночь"),
        .init(id: "Ice", label: "Гололёд"),
        .init(id: "Blizzard", label: "Метель"),
        .init(id: "Hail", label: "Град"),
        .init(id: "Dust", label: "Пыльная буря"),
        .init(id: "Heat", label: "Экстремальная жара"),
        .init(id: "Frost", label: "Экстремальный мороз"),
    ]
    func update(forecast: PointWeather?, coordinate: GeoPoint?, force: Bool = false) {
        self.forecast = forecast; self.coordinate = coordinate
        evaluate(force: force)
    }
    func evaluate(force: Bool = false) {
        let app = UIApplication.shared
        actual = app.alternateIconName.map { String($0.dropFirst(7)) } ?? "Original"
        guard app.applicationState == .active, !busy else { return }
        let now = Date()
        let choice = resolve(now)
        reason = choice.1
        guard choice.0 != actual else { pending = nil; error = ""; attempted = nil; return }
        guard Self.entries.contains(where: { $0.id == choice.0 }) else { return }
        guard app.supportsAlternateIcons else { error = "Смена значка недоступна в этой сборке"; return }
        if force { attempted = nil }
        if !force && mode == "auto" && choice.1 == "Погода" {
            if pending != choice.0 { pending = choice.0; pendingSince = now; return }
            guard now.timeIntervalSince(pendingSince) >= 300,
                  now.timeIntervalSince1970 - lastChange >= 7200 else { return }
        }
        guard attempted != choice.0 else { return }
        attempted = choice.0; busy = true; error = ""
        app.setAlternateIconName(choice.0 == "Original" ? nil : "AppIcon" + choice.0) { [weak self] e in
            Task { @MainActor in
                guard let self else { return }
                self.busy = false
                self.actual = UIApplication.shared.alternateIconName.map { String($0.dropFirst(7)) } ?? "Original"
                if let e { self.error = e.localizedDescription } else { self.lastChange = Date().timeIntervalSince1970; self.pending = nil; self.attempted = nil }
            }
        }
    }
    private func resolve(_ date: Date) -> (String,String) {
        if mode == "original" { return ("Original","Оригинальная") }
        if mode == "manual" { return (manual,"Ручной выбор") }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Asia/Almaty") ?? .current
        let c = cal.dateComponents([.year,.month,.day,.hour,.minute], from: date)
        let m = c.month ?? 1, d = c.day ?? 1, y = c.year ?? 2027
        let season = [12,1,2].contains(m) ? "Winter" : m <= 5 ? "Spring" : m <= 8 ? "Summer" : "Autumn"
        if holidays {
            let fixed: [Int:String] = [101:"NewYear",102:"NewYear",1231:"NewYear",107:"Christmas",308:"Women",321:"Nauryz",322:"Nauryz",323:"Nauryz",501:"Unity",507:"Defender",509:"Victory",706:"Capital",1025:"Republic",1216:"Independence"]
            if let h = fixed[m*100+d] { return (h,"Праздник Казахстана") }
            if (y >= 2027 && m == 3 && d == 15) || (y < 2026 && m == 8 && d == 30) { return ("Constitution","Праздник Казахстана") }
            let key = String(format:"%04d-%02d-%02d",y,m,d)
            if eidDates.split(whereSeparator: { $0.isWhitespace || $0 == "," }).contains(where: { String($0) == key }) { return ("Eid","Праздник Казахстана") }
        }
        var w: WeatherHour?
        if let f = forecast, let p = coordinate,
           abs(date.timeIntervalSince(f.retrievedAt)) <= 10800,
           CLLocation(latitude:f.latitude,longitude:f.longitude).distance(from: CLLocation(latitude:p.latitude,longitude:p.longitude)) <= 10000,
           abs(date.timeIntervalSince(f.current.timestamp)) <= 10800 {
            w = f.current
        }
        if weather, let w {
            let code = w.weatherCode ?? -1, wind = w.windSpeedKmh ?? 0, gust = w.windGustKmh ?? 0
            let windy = wind >= 43.2 || gust >= 64.8 || (actual == "Wind" && (wind >= 36 || gust >= 54))
            let snow = (71...77).contains(code) || (85...86).contains(code)
            if code == 96 || code == 99 { return ("Hail","Погода") }
            if code == 95 { return ("Thunderstorm","Погода") }
            if [56,57,66,67].contains(code) { return ("Ice","Погода") }
            if snow && windy { return ("Blizzard","Погода") }
            if snow { return ("Snow","Погода") }
            if [51,53,55,61,63,65,80,81,82].contains(code) { return ("Rain","Погода") }
            if [45,48].contains(code) { return ("Fog","Погода") }
            if let t = w.temperatureC, t >= 40 { return ("Heat","Погода") }
            if let t = w.temperatureC, t <= -35 { return ("Frost","Погода") }
            if windy { return ("Wind","Погода") }
        }
        if daytime, let p = coordinate {
            // NOAA-style approximate solar elevation; local computation, no network.
            let day = Double(cal.ordinality(of:.day,in:.year,for:date) ?? 1)
            var utc = Calendar(identifier:.gregorian); utc.timeZone = TimeZone(secondsFromGMT:0)!
            let u = utc.dateComponents([.hour,.minute],from:date)
            let hour = Double(u.hour ?? 0) + Double(u.minute ?? 0)/60
            let g = 2*Double.pi/365*(day-1+(hour-12)/24)
            let eq = 229.18*(0.000075+0.001868*cos(g)-0.032077*sin(g)-0.014615*cos(2*g)-0.040849*sin(2*g))
            let dec = 0.006918-0.399912*cos(g)+0.070257*sin(g)-0.006758*cos(2*g)+0.000907*sin(2*g)-0.002697*cos(3*g)+0.00148*sin(3*g)
            let minutes = (hour*60+eq+4*p.longitude).truncatingRemainder(dividingBy:1440)
            let angle = ((minutes+1440).truncatingRemainder(dividingBy:1440)/4-180)*Double.pi/180
            let lat = p.latitude*Double.pi/180
            let elevation = asin(max(-1,min(1,sin(lat)*sin(dec)+cos(lat)*cos(dec)*cos(angle))))*180/Double.pi
            if abs(elevation) <= 5 { return (angle < 0 ? "Sunrise":"Sunset","Время суток") }
            if elevation < -5 { return (seasons ? season+"Night":"Night","Время суток") }
        }
        if weather, let code = w?.weatherCode {
            if [0,1].contains(code) { return ("Sunny","Погода") }
            if [2,3].contains(code) { return ("Cloudy","Погода") }
        }
        return seasons ? (season,"Сезон") : ("Original","Оригинальная")
    }
}

struct AdaptiveIconSettings: View {
    @ObservedObject var manager: AdaptiveIconManager
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Режим") {
                    Picker("Оформление", selection: $manager.mode) {
                        Text("Оригинальная").tag("original")
                        Text("Автоматически").tag("auto")
                        Text("Вручную").tag("manual")
                    }
                    if manager.mode == "auto" {
                        Toggle("Праздники Казахстана",isOn:$manager.holidays)
                        Toggle("Погода",isOn:$manager.weather)
                        Toggle("Время суток",isOn:$manager.daytime)
                        Toggle("Сезоны",isOn:$manager.seasons)
                    }
                }
                if manager.mode == "manual" {
                    Section("Выбор значка") {
                        ForEach(AdaptiveIconManager.entries) { entry in
                            Button { manager.manual = entry.id } label: {
                                HStack {
                                    if entry.id != "Original" { Image("AppIcon"+entry.id+"Preview").resizable().frame(width:48,height:48).clipShape(RoundedRectangle(cornerRadius:10)) }
                                    Text(entry.label).foregroundStyle(.primary)
                                    Spacer()
                                    if manager.manual == entry.id { Image(systemName:"checkmark.circle.fill") }
                                }
                            }
                        }
                    }
                }
                if manager.mode == "auto" && manager.holidays {
                    Section("Курбан айт · официальные даты") {
                        TextField("ГГГГ-ММ-ДД",text:$manager.eidDates).autocorrectionDisabled().textInputAutocapitalization(.never)
                        Text("Добавляйте подтверждённые даты через запятую. Не вычисляются автоматически.").font(.caption)
                    }
                }
                Section("Состояние") {
                    Text("Текущий: " + (AdaptiveIconManager.entries.first { $0.id == manager.actual }?.label ?? manager.actual))
                    Text(manager.reason)
                    if !manager.error.isEmpty { Text(manager.error).foregroundStyle(.red) }
                    Button("Применить") { manager.evaluate(force:true) }
                    Text("iOS может показывать системное уведомление при смене значка. Автоматическая смена работает при активном приложении.").font(.caption)
                }
            }.navigationTitle("Значок приложения").toolbar { ToolbarItem(placement:.confirmationAction) { Button("Готово") { dismiss() } } }
        }
    }
}
