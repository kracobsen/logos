import Domain

/// The cold launch → interactive Library signpost. Begun at app start, ended the first time the Library (or, when
/// signed out, sign-in) appears.
public final class LaunchSignpost {
    private var interval: SignpostInterval?

    public init() {
        interval = Signposts.begin(.coldLaunchToInteractiveLibrary)
    }

    /// Ends the interval; later calls do nothing.
    public func end() {
        interval?.end()
        interval = nil
    }
}
