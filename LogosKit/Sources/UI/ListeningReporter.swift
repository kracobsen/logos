import Domain
import Foundation
import Network
import Playback
import Sync
import UIKit

/// The network seam for "the network came back": whether any network path is usable now, then on each change.
public protocol ConnectivityMonitor: Sendable {
    func connectedUpdates() -> AsyncStream<Bool>
}

/// The real one, from `NWPathMonitor`: connected when the path is satisfied (any interface, cellular included).
public struct SystemConnectivityMonitor: ConnectivityMonitor {
    public init() {}

    public func connectedUpdates() -> AsyncStream<Bool> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "Logos connectivity monitor"))
        }
    }
}

/// The seam for the short background task a send gets when it may outlive the app being in front.
public protocol BackgroundTasks {
    /// Begins a background task; call the returned closure when the work is done.
    func begin(_ name: String) -> () -> Void
}

/// The real one: `UIApplication.beginBackgroundTask`. If time runs out first, the task just ends; the send is
/// retried at the next trigger.
public struct SystemBackgroundTasks: BackgroundTasks {
    public init() {}

    public func begin(_ name: String) -> () -> Void {
        let task = Running()
        task.identifier = UIApplication.shared.beginBackgroundTask(withName: name) { task.end() }
        return { task.end() }
    }

    private final class Running {
        var identifier = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard identifier != .invalid else { return }
            UIApplication.shared.endBackgroundTask(identifier)
            identifier = .invalid
        }
    }
}

/// Runs the outbox's send triggers for a signed-in identity: on launch, every 60 s while playing, straight away
/// when playing stops (pause, Sleep Timer, end of Book, a switch, a stop) and on going to the background (both
/// with a short background task), on returning to the foreground, and when the network comes back.
///
/// Sends are fire-and-forget: playback never waits for them, and failures wait for the next trigger.
public final class ListeningReporter {
    private let outbox: SessionOutbox
    private let player: Player?
    private let connectivity: (any ConnectivityMonitor)?
    private let backgroundTasks: any BackgroundTasks

    /// - Parameters:
    ///   - player: whose stops send straight away. Without it, only the other triggers run.
    ///   - connectivity: for sending when the network comes back. Without it, that trigger doesn't run.
    public init(
        outbox: SessionOutbox,
        player: Player?,
        connectivity: (any ConnectivityMonitor)? = SystemConnectivityMonitor(),
        backgroundTasks: any BackgroundTasks = SystemBackgroundTasks()
    ) {
        self.outbox = outbox
        self.player = player
        self.connectivity = connectivity
        self.backgroundTasks = backgroundTasks
    }

    /// Sends now (the launch trigger), then follows the other triggers until cancelled.
    public func run() async {
        let outbox = outbox
        // Subscribed before anything else runs, so no stop is missed while the triggers start.
        let stops = player?.stops()
        await withDiscardingTaskGroup { group in
            group.addTask { await outbox.send() }
            group.addTask { await outbox.sendWhilePlaying() }
            group.addTask { await outbox.sendOnFinishedChanges() }
            group.addTask { await self.sendOnStops(stops) }
            group.addTask { await self.sendWhenConnected() }
        }
    }

    /// The app came back to the foreground.
    public func enteredForeground() {
        let outbox = outbox
        Task { await outbox.send() }
    }

    /// The app is going to the background: sends with a short background task.
    public func enteredBackground() {
        sendInBackgroundTask()
    }

    private func sendOnStops(_ stops: AsyncStream<PlaybackStop>?) async {
        guard let stops else { return }
        for await _ in stops {
            sendInBackgroundTask()
        }
    }

    private func sendWhenConnected() async {
        guard let connectivity else { return }
        var wasConnected: Bool?
        for await connected in connectivity.connectedUpdates() {
            defer { wasConnected = connected }
            guard connected, wasConnected == false else { continue }
            await outbox.send()
        }
    }

    private func sendInBackgroundTask() {
        let end = backgroundTasks.begin("Send listening")
        let outbox = outbox
        Task {
            await outbox.send()
            end()
        }
    }
}
