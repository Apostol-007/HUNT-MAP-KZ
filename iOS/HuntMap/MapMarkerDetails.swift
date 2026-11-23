import SwiftUI
import UIKit
import HuntCore

struct MapMarkerSelection: Identifiable {
    let id: UUID
}

/// Full marker operations, backed by FieldModel rather than transient map annotations.
struct MapMarkerDetails: View {
    @Environment(\.dismiss) private var dismiss
    let markerID: UUID
    @ObservedObject var model: FieldModel
    let onShowOnMap: (GeoPoint) -> Void
    let onMove: () -> Void
    let onNavigate: (UUID) -> Void
    @State private var confirmDelete = false
    @State private var showCopied = false

    private var marker: Marker? { model.markers.first(where: { $0.id == markerID }) }

    var body: some View {
        NavigationStack {
            Group {
                if let marker {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            HStack(spacing: 13) {
                                Image(systemName: marker.symbol ?? MarkerStyle.defaultSymbol(for: marker.kind))
                                    .font(.system(size: 27, weight: .bold))
                                    .foregroundStyle(Color(hex: marker.colorHex ?? "#24DA66"))
                                    .frame(width: 54, height: 54)
                                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(marker.title).font(.title3.bold()).foregroundStyle(.white)
                                    Text(marker.kind).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Координаты WGS84").font(.caption).foregroundStyle(.secondary)
                                Text(String(format: "%.7f, %.7f", marker.coordinate.latitude, marker.coordinate.longitude))
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                                Text("Создана: \(marker.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(15)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

                            NavigationLink {
                                MarkerEditor(marker: marker,
                                             onSave: { model.saveMarker($0) },
                                             onDelete: { model.deleteMarker(id: $0); dismiss() })
                            } label: {
                                actionRow("Редактировать название, тип, цвет и координаты", "pencil")
                            }
                            Button { onMove() } label: { actionRow("Переместить на карте", "hand.point.up.left.fill") }
                            Button { onShowOnMap(marker.coordinate) } label: { actionRow("Показать на карте", "location.viewfinder") }
                            Button {
                                UIPasteboard.general.string = String(format: "%.7f, %.7f", marker.coordinate.latitude, marker.coordinate.longitude)
                                showCopied = true
                            } label: { actionRow("Скопировать координаты", "doc.on.doc") }
                            ShareLink(item: shareText(marker)) {
                                actionRow("Поделиться меткой", "square.and.arrow.up")
                            }
                            Button { onNavigate(markerID) } label: {
                                actionRow("Маршрут внутри HUNT MAP KZ", "arrow.triangle.turn.up.right.diamond")
                            }
                            Button(role: .destructive) { confirmDelete = true } label: {
                                actionRow("Удалить метку", "trash", destructive: true)
                            }
                        }
                        .padding(18)
                    }
                } else {
                    ContentUnavailableView("Метка удалена", systemImage: "mappin.slash")
                }
            }
            .background(Color(hex: "#050808").ignoresSafeArea())
            .navigationTitle("Управление меткой")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
            .confirmationDialog("Удалить метку без возможности восстановления?", isPresented: $confirmDelete) {
                Button("Удалить", role: .destructive) {
                    model.deleteMarker(id: markerID)
                    dismiss()
                }
                Button("Отмена", role: .cancel) { }
            }
            .alert("Координаты скопированы", isPresented: $showCopied) { Button("OK") {} }
        }
    }

    private func actionRow(_ title: String, _ symbol: String, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: 25)
            Text(title).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption)
        }
        .foregroundStyle(destructive ? Color.red : Color.white)
        .padding(13)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
        .contentShape(Rectangle())
    }

    private func shareText(_ marker: Marker) -> String {
        "\(marker.title) · HUNT MAP KZ\nКоординаты: \(marker.coordinate.latitude), \(marker.coordinate.longitude)\nhttps://maps.apple.com/?ll=\(marker.coordinate.latitude),\(marker.coordinate.longitude)"
    }
}
