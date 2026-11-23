import Foundation
import Network

/// Connectivity only triggers refresh attempts; URLSession remains the authority on success.
@MainActor final class WeatherConnectivity: ObservableObject {
    @Published private(set) var connected = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "kz.huntmap.weather.connectivity")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            Task { @MainActor [weak self] in self?.connected = reachable }
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}