import os

/// A path with a performance budget in `docs/performance-budgets.md`.
///
/// Each budgeted path is marked with a signpost interval under subsystem ``Diagnostics/subsystem``,
/// category ``Diagnostics/budgetCategory`` and its ``signpostName``, so Instruments and
/// `XCTOSSignpostMetric` can measure it. Add a case here when a new budget is added to the table.
public enum BudgetedPath: CaseIterable, Sendable {
    case coldLaunchToInteractiveLibrary
    case returnFromBackground
    case lastPlayedBookReady
    case letterIndexJump
    case searchKeystroke
    case sortChange
    case tapBookToDetail
    case playLoadedBook
    case playOtherBook
    case seekToAudio
    case syncWithNoChanges
    case firstSync
    case applyFetchedProgress

    /// The signpost interval name. `OSSignposter` needs a `StaticString`, hence the switch.
    public var signpostName: StaticString {
        switch self {
        case .coldLaunchToInteractiveLibrary: "ColdLaunchToInteractiveLibrary"
        case .returnFromBackground: "ReturnFromBackground"
        case .lastPlayedBookReady: "LastPlayedBookReady"
        case .letterIndexJump: "LetterIndexJump"
        case .searchKeystroke: "SearchKeystroke"
        case .sortChange: "SortChange"
        case .tapBookToDetail: "TapBookToDetail"
        case .playLoadedBook: "PlayLoadedBook"
        case .playOtherBook: "PlayOtherBook"
        case .seekToAudio: "SeekToAudio"
        case .syncWithNoChanges: "SyncWithNoChanges"
        case .firstSync: "FirstSync"
        case .applyFetchedProgress: "ApplyFetchedProgress"
        }
    }
}

/// Signposts for budgeted paths.
///
/// Wrap work that runs start to finish in ``measure(_:isolation:_:)`` or ``measureSync(_:_:)``.
/// For a path that starts and ends in different callbacks, call ``begin(_:)`` and keep the
/// returned ``SignpostInterval`` until the path ends.
public enum Signposts {
    static let signposter = OSSignposter(subsystem: Diagnostics.subsystem, category: Diagnostics.budgetCategory)

    public static func begin(_ path: BudgetedPath) -> SignpostInterval {
        let name = path.signpostName
        let state = signposter.beginInterval(name, id: signposter.makeSignpostID())
        return SignpostInterval(name: name, state: state)
    }

    public static func measure<T, E: Error>(
        _ path: BudgetedPath,
        isolation: isolated (any Actor)? = #isolation,
        _ work: () async throws(E) -> T
    ) async throws(E) -> T {
        let interval = begin(path)
        defer { interval.end() }
        return try await work()
    }

    public static func measureSync<T, E: Error>(_ path: BudgetedPath, _ work: () throws(E) -> T) throws(E) -> T {
        let interval = begin(path)
        defer { interval.end() }
        return try work()
    }
}

/// An open signpost interval on a budgeted path. Call ``end()`` exactly once.
public struct SignpostInterval: Sendable {
    let name: StaticString
    let state: OSSignpostIntervalState

    public func end() {
        Signposts.signposter.endInterval(name, state)
    }
}
