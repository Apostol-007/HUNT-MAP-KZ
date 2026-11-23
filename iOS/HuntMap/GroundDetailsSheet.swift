import SwiftUI
import HuntCore

struct GroundDetailsSheet: View {
    let zone: GeoZone
    @Environment(\.dismiss) private var dismiss
    private var fields: [(key: String, value: String)] {
        (zone.attributes ?? [:]).map { (key: $0.key, value: $0.value) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }
    var body: some View {
        NavigationStack {
            List {
                Section("Общая информация") {
                    LabeledContent("Название", value: zone.name)
                    LabeledContent("Тип", value: zone.kind == .protectedArea ? "Охраняемая территория" : "Охотничье хозяйство")
                    LabeledContent("Достоверность", value: zone.verified ? "Верифицировано" : "Не подтверждено")
                    LabeledContent("Источник", value: zone.source)
                }
                Section("Все атрибуты источника · \(fields.count)") {
                    if fields.isEmpty {
                        Text("В GeoJSON отсутствуют атрибуты хозяйства. Их нельзя восстановить по одной геометрии.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(fields.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(fields[index].key).font(.caption).foregroundStyle(.secondary)
                            Text(fields[index].value.isEmpty ? "Нет данных" : fields[index].value)
                                .font(.body).textSelection(.enabled)
                        }.padding(.vertical, 3)
                    }
                }
                Section {
                    Text("Данные информационные. Актуальность границ, договоров и разрешений необходимо проверить по первоисточнику.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(HuntReference.background)
            .navigationTitle(zone.name).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
        }
    }
}
