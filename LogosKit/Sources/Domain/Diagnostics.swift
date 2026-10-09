import os

/// One logger category per module. Each module keeps a `log` constant made from its own category.
public enum LogCategory: String, Sendable, CaseIterable {
    case app = "App"
    case domain = "Domain"
    case serverAPI = "ServerAPI"
    case store = "Store"
    case sync = "Sync"
    case downloads = "Downloads"
    case playback = "Playback"
    case ui = "UI"
}

/// Logging and signposts for every module.
///
/// Instruments and `XCTOSSignpostMetric` read signposts by subsystem, category and name,
/// so those three are fixed here rather than derived from the bundle identifier.
public enum Diagnostics {
    public static let subsystem = "Logos"

    /// The signpost category every budgeted path is recorded under.
    public static let budgetCategory = "Budgets"

    public static func logger(_ category: LogCategory) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }
}
