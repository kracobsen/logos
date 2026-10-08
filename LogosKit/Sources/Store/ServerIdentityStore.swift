import Domain
import Foundation
import GRDB

/// The Server identity row. Its presence means signed in.
struct ServerIdentityRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "serverIdentity"

    var id = 1
    var serverURL: String
    var userID: String
    var username: String
    var libraryID: String
    var libraryName: String

    init(_ identity: ServerIdentity) {
        serverURL = identity.serverURL.absoluteString
        userID = identity.userID
        username = identity.username
        libraryID = identity.libraryID
        libraryName = identity.libraryName
    }

    var identity: ServerIdentity? {
        guard let url = URL(string: serverURL) else { return nil }
        return ServerIdentity(
            serverURL: url,
            userID: userID,
            username: username,
            libraryID: libraryID,
            libraryName: libraryName
        )
    }
}

extension AppDatabase {
    /// The identity Logos is signed in as, or `nil` when signed out.
    public func serverIdentity() throws -> ServerIdentity? {
        try pool.read { db in try ServerIdentityRecord.fetchOne(db)?.identity }
    }

    /// Records a completed sign-in, replacing any previous identity.
    public func saveServerIdentity(_ identity: ServerIdentity) throws {
        try pool.write { db in try ServerIdentityRecord(identity).upsert(db) }
    }

    /// The identity now, then again each time it changes.
    public func serverIdentityUpdates() -> AsyncThrowingStream<ServerIdentity?, any Error> {
        let values =
            ValueObservation
            .tracking { db in try ServerIdentityRecord.fetchOne(db)?.identity }
            .removeDuplicates()
            .values(in: pool)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
