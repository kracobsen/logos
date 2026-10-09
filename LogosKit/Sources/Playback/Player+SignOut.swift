import Domain
import Store

/// The player outlives identities, so signing out resets it by hand.
extension Player {
    /// Signing out: the loaded Book is stopped (saved, its listening session ended) and unloaded, and any damage
    /// notice goes.
    public func signOut() {
        if let bookID = book?.id { stop(bookID: bookID) }
        dismissDamage()
    }

    /// Reads the speed and skip intervals from the Store again: after the sign-out wipe, the defaults.
    public func reloadSettings() {
        let settings = Self.readSettings(database)
        speed = settings.speed
        skipBackInterval = settings.skipBack
        skipForwardInterval = settings.skipForward
        audio.rate = Float(settings.speed)
    }
}
