import SwiftUI
import UIKit
import HuntCore

enum MarkerStyle {
    static let choices: [(String, String)] = [
        ("car.fill", "Автомобиль"), ("car.side.fill", "Машина сбоку"),
        ("suv.side.fill", "Внедорожник"), ("truck.box.fill", "Грузовик"),
        ("figure.walk", "Человек"), ("figure.hiking", "Турист"),
        ("pawprint.fill", "Животное"), ("hare.fill", "Заяц"),
        ("tortoise.fill", "Черепаха"), ("bird.fill", "Птица"),
        ("fish.fill", "Рыба"), ("ant.fill", "Насекомое"),
        ("mappin", "Точка"), ("mappin.circle.fill", "Круглая метка"),
        ("flag.fill", "Флаг"), ("circle.fill", "Круг"),
        ("scope", "Прицел"), ("tent.fill", "Лагерь"),
        ("house.fill", "Дом"), ("cross.case.fill", "Аптечка")
    ]
    static let colors = ["#FF9F0A", "#FF453A", "#30D158", "#0A84FF", "#BF5AF2", "#FFD60A", "#FFFFFF", "#8E8E93", "#000000"]
    static func defaultSymbol(for kind: String) -> String {
        if kind.contains("Машин") { return "car.fill" }
        if kind.contains("Егер") { return "figure.walk" }
        return "mappin.circle.fill"
    }
}

extension UIColor {
    convenience init(hex: String) {
        let text = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(text, radix: 16) ?? 0xFF9F0A
        self.init(red: CGFloat((value >> 16) & 255) / 255,
                  green: CGFloat((value >> 8) & 255) / 255,
                  blue: CGFloat(value & 255) / 255, alpha: 1)
    }
}
extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }
}

struct MarkerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var marker: Marker
    let onSave: (Marker) -> Void
    let onDelete: (UUID) -> Void
    var isNew = false
    @State private var latitude: String
    @State private var longitude: String
    @State private var confirmDelete = false

    init(marker: Marker, isNew: Bool = false, onSave: @escaping (Marker) -> Void, onDelete: @escaping (UUID) -> Void) {
        self.isNew = isNew
        _marker = State(initialValue: marker)
        _latitude = State(initialValue: String(format: "%.7f", marker.coordinate.latitude))
        _longitude = State(initialValue: String(format: "%.7f", marker.coordinate.longitude))
        self.onSave = onSave
        self.onDelete = onDelete
    }
    private var validCoordinates: Bool {
        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
              let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")) else { return false }
        return lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Название") {
                    TextField("Название метки", text: $marker.title)
                    HStack {
                        Spacer()
                        Image(systemName: marker.symbol ?? MarkerStyle.defaultSymbol(for: marker.kind))
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Color(hex: marker.colorHex ?? "#FF9F0A"))
                        Spacer()
                    }.padding(.vertical, 10)
                }
                Section("Выбрать значок") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(MarkerStyle.choices, id: \.0) { choice in
                            Button {
                                marker.symbol = choice.0
                                marker.kind = choice.1
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: choice.0).font(.title2)
                                    Text(choice.1).font(.system(size: 9)).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, minHeight: 54)
                                .foregroundStyle((marker.symbol ?? MarkerStyle.defaultSymbol(for: marker.kind)) == choice.0 ? Color.white : Color.primary)
                                .background((marker.symbol ?? MarkerStyle.defaultSymbol(for: marker.kind)) == choice.0 ? Color.accentColor : Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 8)
                }
                Section("Цвет метки") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 10) {
                        ForEach(MarkerStyle.colors, id: \.self) { hex in
                            Button { marker.colorHex = hex } label: {
                                Circle().fill(Color(hex: hex))
                                    .frame(width: 35, height: 35)
                                    .overlay { Circle().strokeBorder(.gray.opacity(0.3), lineWidth: 1) }
                                    .overlay {
                                        if (marker.colorHex ?? "#FF9F0A") == hex {
                                            Image(systemName: "checkmark").font(.caption.bold())
                                                .foregroundStyle(hex == "#FFFFFF" ? Color.black : Color.white)
                                        }
                                    }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.vertical, 6)
                }
                Section("Координаты") {
                    TextField("Широта", text: $latitude).keyboardType(.numbersAndPunctuation)
                    TextField("Долгота", text: $longitude).keyboardType(.numbersAndPunctuation)
                    Text("Чтобы переместить метку на карте: удерживайте её пальцем, затем отпустите в новом месте. Можно также ввести точные координаты здесь.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !isNew {
                    Section {
                        Button("Удалить метку", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(FBTheme.background)
            .navigationTitle(isNew ? "Новая метка" : "Редактор метки")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") {
                        guard let lat = Double(latitude.replacingOccurrences(of: ",", with: ".")),
                              let lon = Double(longitude.replacingOccurrences(of: ",", with: ".")) else { return }
                        marker.coordinate = GeoPoint(lat, lon)
                        onSave(marker)
                        dismiss()
                    }.disabled(!validCoordinates || marker.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Удалить эту метку?", isPresented: $confirmDelete) {
                Button("Удалить", role: .destructive) { onDelete(marker.id); dismiss() }
            }
        }
    }
}
