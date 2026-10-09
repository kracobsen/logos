import Observation
import Sync

/// The sign-in screen: Server address, username and password on one screen, errors in place, and a Library pick
/// when the Server has several book Libraries.
@Observable
public final class SignInModel {
    /// Where an error is shown on the screen.
    public enum ErrorPlacement: Sendable, Hashable {
        /// Under the Server address.
        case address
        /// Under the username and password.
        case credentials
        /// Under the Sign In button.
        case general
    }

    public var address = ""
    public var username = ""
    public var password = ""

    public private(set) var isWorking = false
    public private(set) var error: SignInError?
    /// The book Libraries to pick from; empty unless a pick is pending.
    public var libraryOptions: [LibraryOption] { pendingChoice?.libraries ?? [] }

    private var pendingChoice: LibraryChoice?
    private let signIn: SignIn

    public init(signIn: SignIn) {
        self.signIn = signIn
    }

    public var canSubmit: Bool {
        !isWorking && [address, username, password].allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    public func submit() async {
        guard canSubmit else { return }
        isWorking = true
        error = nil
        pendingChoice = nil
        defer { isWorking = false }
        do {
            switch try await signIn.signIn(address: address, username: username, password: password) {
            case .signedIn:
                password = ""
            case .chooseLibrary(let choice):
                password = ""
                pendingChoice = choice
            }
        } catch {
            self.error = error
        }
    }

    public func choose(_ library: LibraryOption) {
        guard let choice = pendingChoice else { return }
        do {
            _ = try signIn.choose(library, from: choice)
            pendingChoice = nil
        } catch {
            self.error = error
        }
    }

    /// Drops a pending Library pick (revoking it on the Server); the user has to sign in again.
    public func cancelLibraryChoice() {
        guard let choice = pendingChoice else { return }
        pendingChoice = nil
        let signIn = signIn
        Task { await signIn.cancel(choice) }
    }

    public var errorPlacement: ErrorPlacement? { error.map(Self.placement(for:)) }

    public var errorMessage: String? { error.map(Self.message(for:)) }

    /// Where an error shows on a sign-in form.
    static func placement(for error: SignInError) -> ErrorPlacement {
        switch error {
        case .invalidAddress, .httpsRequired, .cantReachServer, .serverTooOld, .localSignInNotAllowed,
            .differentServer:
            .address
        case .wrongCredentials, .tooManyAttempts, .differentUser: .credentials
        case .noBookLibrary, .serverError, .couldNotSave: .general
        }
    }

    /// What a sign-in form says about an error.
    static func message(for error: SignInError) -> String {
        switch error {
        case .invalidAddress: "Enter the Server's address, like abs.example.com."
        case .httpsRequired: "Logos only connects over HTTPS. Use an https:// address."
        case .cantReachServer: "Can't reach the Server. Check the address and your connection."
        case .serverTooOld(let found):
            "Server too old: it runs audiobookshelf \(found), and Logos needs 2.36 or later."
        case .localSignInNotAllowed: "This Server doesn't allow signing in with a username and password."
        case .wrongCredentials: "Wrong username or password."
        case .tooManyAttempts: "Too many sign-in attempts. Wait a few minutes and try again."
        case .noBookLibrary: "No book Library: this account can't see any audiobook Library on the Server."
        case .serverError(let code): "The Server returned an error (\(code)). Try again later."
        case .couldNotSave: "Couldn't save the sign-in on this iPhone. Try again."
        case .differentServer:
            "That's a different Server. To change Server, sign out in Settings, then sign in again."
        case .differentUser:
            "That's a different account. To change account, sign out in Settings, then sign in again."
        }
    }
}
