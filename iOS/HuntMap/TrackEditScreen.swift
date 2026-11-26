import SwiftUI
import HuntCore

struct TrackEditScreen: View {
    @ObservedObject var model: FieldModel
    let source: Track
    @Environment(\.dismiss) private var dismiss
    @State private var mode = Mode.trim
    @State private var start = 0
    @State private var end: Int
    @State private var cut: Int
    @State private var secondID: UUID?
    @State private var name: String
    @State private var error = ""
    private enum Mode: String, CaseIterable, Identifiable {
        case trim = "Обрезка", split = "Разделение", join = "Объединение"
        var id: String { rawValue }
    }
    init(model: FieldModel, source: Track) {
        self.model = model; self.source = source
        _end = State(initialValue: max(0, source.fixes.count - 1))
        _cut = State(initialValue: max(1, source.fixes.count / 2))
        _name = State(initialValue: source.name + " · копия")
    }
    private var candidates: [Track] {
        model.tracks.filter { $0.id != source.id && $0.fixes.count >= 2 }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Исходный маршрут") {
                    Text(source.name)
                    Text("\(source.fixes.count) GPS-точек · \(String(format: "%.2f", source.distanceMeters / 1000)) км")
                        .font(.caption)
                    TextField("Название копии", text: $name)
                }
                Section("Операция") {
                    Picker("Действие", selection: $mode) {
                        ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    switch mode {
                    case .trim:
                        if source.fixes.count >= 2 {
                            Stepper("Начало: \(start + 1)", value: $start, in: 0...max(0, end - 1))
                            Stepper("Конец: \(end + 1)", value: $end, in: min(start + 1, source.fixes.count - 1)...(source.fixes.count - 1))
                            pointDetail(start)
                            pointDetail(end)
                        }
                    case .split:
                        if source.fixes.count >= 3 {
                            Stepper("Разделить в точке \(cut + 1)", value: $cut, in: 1...(source.fixes.count - 2))
                            pointDetail(cut)
                        } else { Text("Нужно минимум три точки") }
                    case .join:
                        Picker("Вторая запись", selection: $secondID) {
                            Text("Выберите маршрут").tag(UUID?.none)
                            ForEach(candidates) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Text("Записи упорядочиваются по времени. Между ними сохраняется разрыв; путь между записями не дорисовывается. Пересекающиеся по времени записи не объединяются.")
                            .font(.caption)
                    }
                }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
                Section {
                    Button("Сохранить новые маршруты") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || source.fixes.count < 2)
                        .accessibilityIdentifier("track_editor_save")
                    Text("Оригиналы остаются без изменений.").font(.caption)
                }
            }
            .navigationTitle("Редактор маршрута")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Отмена") { dismiss() } } }
        }
    }
    private func pointDetail(_ index: Int) -> some View {
        Group {
            if source.fixes.indices.contains(index) {
                let fix = source.fixes[index]
                Text("\(index + 1) · \(fix.timestamp.formatted(date: .abbreviated, time: .standard)) · \(String(format: "%.5f, %.5f", fix.point.latitude, fix.point.longitude))")
                    .font(.caption.monospacedDigit())
            }
        }
    }
    private func copy(_ points: [TrackFix], title: String) -> Track {
        var fixes = points
        fixes[0].segmentStart = true
        var result = Track(name: title, createdAt: fixes[0].timestamp, fixes: fixes, sessionEnd: fixes.last?.timestamp)
        result.cacheStatistics()
        return result
    }
    private func save() {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var copies: [Track]
        switch mode {
        case .trim:
            guard let points = TrackEdit.trim(source.fixes, start: start, end: end) else { error = "Некорректный диапазон"; return }
            copies = [copy(points, title: title)]
        case .split:
            guard let (a,b) = TrackEdit.split(source.fixes, at: cut) else { error = "Некорректная точка разделения"; return }
            copies = [copy(a, title: title + " · 1"), copy(b, title: title + " · 2")]
        case .join:
            guard let second = candidates.first(where: { $0.id == secondID }),
                  let a = source.fixes.first, let b = second.fixes.first else { error = "Выберите второй маршрут"; return }
            let first = a.timestamp <= b.timestamp ? source.fixes : second.fixes
            let last = a.timestamp <= b.timestamp ? second.fixes : source.fixes
            guard let points = TrackEdit.join(first, last, timestamp: { $0.timestamp }, startSegment: { fix in
                var copy = fix; copy.segmentStart = true; return copy
            }) else { error = "Записи пересекаются по времени или содержат неупорядоченные точки"; return }
            copies = [copy(points, title: title)]
        }
        do { try model.saveEditedTracks(copies); dismiss() }
        catch { self.error = "Не удалось сохранить: " + error.localizedDescription }
    }
}
