import Foundation
import Network

/// The network seam for showing "Waiting for Wi-Fi": whether a network Downloads may use without cellular is there.
///
/// The transfers themselves wait for the right network on their own (a background session waits for connectivity);
/// this is only for telling the listener why nothing moves.
public protocol NetworkMonitor: Sendable {
    /// Whether unconstrained Wi-Fi (or wired) is usable now, then again on each change.
    func wifiUpdates() -> AsyncStream<Bool>
}

/// The real one, from `NWPathMonitor`. A path counts as Wi-Fi when it's satisfied, not constrained (Low Data Mode),
/// and goes over Wi-Fi or a wired interface.
public struct SystemNetworkMonitor: NetworkMonitor {
    public init() {}

    public func wifiUpdates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(
                    path.status == .satisfied && !path.isConstrained
                        && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "Logos network monitor"))
        }
    }
}
