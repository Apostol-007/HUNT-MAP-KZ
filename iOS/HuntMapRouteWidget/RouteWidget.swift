import SwiftUI
import WidgetKit

struct RouteEntry: TimelineEntry {
    let date: Date
    let snapshot: RouteWidgetSnapshot
}

struct RouteProvider: TimelineProvider {
    func placeholder(in context: Context) -> RouteEntry { RouteEntry(date: .now, snapshot: .empty) }
    func getSnapshot(in context: Context, completion: @escaping (RouteEntry) -> Void) {
        completion(RouteEntry(date: .now, snapshot: RouteWidgetStorage.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<RouteEntry>) -> Void) {
        let entry = RouteEntry(date: .now, snapshot: RouteWidgetStorage.read())
        completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(300))))
    }
}

private func pace(_ seconds: Double?) -> String {
    guard let seconds, seconds.isFinite, seconds >= 0 else { return "—" }
    let total = Int(min(seconds.rounded(), 359999))
    return String(format: "%d:%02d мин/км", total / 60, total % 60)
}

struct RouteWidgetView: View {
    let entry: RouteEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Image(systemName: "figure.hiking").foregroundStyle(.orange)
                Text("HUNT MAP KZ").font(.caption.bold())
                Spacer(minLength: 0)
            }
            Text(entry.snapshot.title).font(.subheadline.bold()).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: "%.2f", entry.snapshot.distanceMeters / 1000))
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                Text("км").font(.caption)
            }
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("СКОРОСТЬ").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(entry.snapshot.speedKmh.map { String(format: "%.1f км/ч", $0) } ?? "—")
                        .font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("СР. ТЕМП").font(.system(size: 9)).foregroundStyle(.secondary)
                    Text(pace(entry.snapshot.averagePaceSecondsPerKm))
                        .font(.caption.bold()).lineLimit(1).minimumScaleFactor(0.7)
                }
            }
            Text(entry.snapshot.status).font(.caption2).lineLimit(1)
            Text("Точек: \(entry.snapshot.pointCount) · \(entry.snapshot.updatedAt, style: .time)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .containerBackground(for: .widget) { Color(.systemBackground) }
        .widgetURL(URL(string: "huntmap://routes"))
    }
}

@main struct HuntMapRouteWidget: Widget {
    let kind = "HuntMapRouteWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RouteProvider()) { entry in
            RouteWidgetView(entry: entry)
        }
        .configurationDisplayName("Мой маршрут")
        .description("Дистанция, скорость и средний темп маршрута")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
