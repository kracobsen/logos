import Domain
import Observation
import Store

/// Decides what launch shows: sign-in when signed out, the tab shell when a Server identity is saved.
///
/// Reads the identity straight away, so a signed-in launch shows the tab shell in its first frame, then follows the
/// database (ADR 0001).
@Observable
public final class LaunchModel {
    public private(set) var identity: ServerIdentity?
    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
        do {
            identity = try database.serverIdentity()
        } catch {
            log.error("Couldn't read the Server identity: \(String(describing: error), privacy: .public)")
        }
    }

    /// Follows the identity in the database until cancelled.
    public func observe() async {
        do {
            for try await identity in database.serverIdentityUpdates() {
                self.identity = identity
            }
        } catch {
            log.error("Stopped observing the Server identity: \(String(describing: error), privacy: .public)")
        }
    }
}
