import Foundation
import Network
import Observation

/// Thin `NWPathMonitor` wrapper so screens can react to the LAN/internet
/// dropping and returning (download robustness, UX-1). Observation-friendly so
/// a SwiftUI view re-renders when `isOnline` flips; starts lazily on first use.
@Observable
@MainActor
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isOnline = true

    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "app.getpocketai.network-monitor")
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }
}
