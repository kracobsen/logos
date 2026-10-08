import Foundation

/// Who and where Logos is signed in as: the Server, the user on it and the chosen Library.
///
/// Its presence in the database is what "signed in" means at launch. Signing in again must match the Server and
/// user id. The username is kept to fill in the sign-in sheet; the password is never kept.
public struct ServerIdentity: Sendable, Hashable, Codable {
    public let serverURL: URL
    public let userID: String
    public let username: String
    public let libraryID: String
    public let libraryName: String

    public init(serverURL: URL, userID: String, username: String, libraryID: String, libraryName: String) {
        self.serverURL = serverURL
        self.userID = userID
        self.username = username
        self.libraryID = libraryID
        self.libraryName = libraryName
    }
}
