import Domain
import Observation
import Store
import Sync

/// Decides what launch shows: sign-in when signed out, the tab shell when a Server identity is saved.
///
/// Reads the identity straight away, so a signed-in launch shows the tab shell (with its Library rows) in its first
/// frame, then follows the database (ADR 0001). While signed in it holds the Library tab's model, built for that
/// identity.
@Observable
public final class LaunchModel {
    public private(set) var identity: ServerIdentity? {
        didSet {
            guard identity != oldValue else { return }
            library = identity.map(makeLibrary)
        }
    }
    /// The Library tab's model, while signed in.
    public private(set) var library: LibraryModel?

    private let database: AppDatabase
    private let makeLibrarySync: (ServerIdentity) -> LibrarySync

    /// - Parameter makeLibrarySync: builds the sync for a signed-in identity (its Server and Library).
    public init(database: AppDatabase, makeLibrarySync: @escaping (ServerIdentity) -> LibrarySync) {
        self.database = database
        self.makeLibrarySync = makeLibrarySync
        do {
            identity = try database.serverIdentity()
        } catch {
            log.error("Couldn't read the Server identity: \(String(describing: error), privacy: .public)")
        }
        library = identity.map(makeLibrary)
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

    private func makeLibrary(for identity: ServerIdentity) -> LibraryModel {
        LibraryModel(database: database, sync: makeLibrarySync(identity))
    }
}
