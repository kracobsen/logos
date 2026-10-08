import Domain
import Foundation
import Observation
import Store

/// The In Progress tab: started, unfinished Books, most recently listened first.
///
/// Rows are read in `init`, so the tab has real rows in its first frame, then follow the database (ADR 0001): a
/// progress fetch or playback that changes a Book reorders the list on its own.
@Observable
public final class InProgressModel {
    public private(set) var rows: [InProgressRow]

    private let database: AppDatabase

    public init(database: AppDatabase) {
        self.database = database
        do {
            rows = try database.inProgressRows()
        } catch {
            log.error("Couldn't read In Progress: \(String(describing: error), privacy: .public)")
            rows = []
        }
    }

    /// Follows the In Progress rows in the database until cancelled.
    public func observe() async {
        do {
            for try await rows in database.inProgressRowUpdates() {
                self.rows = rows
            }
        } catch {
            log.error("Stopped observing In Progress: \(String(describing: error), privacy: .public)")
        }
    }

    /// The progress model for a Book's detail.
    public func progressModel(for row: InProgressRow) -> BookProgressModel {
        BookProgressModel(database: database, bookID: row.id, duration: row.duration)
    }
}

/// How far the listener is in a Book, as Book detail shows it.
nonisolated public enum BookProgressStatus: Sendable, Hashable {
    case notStarted
    /// `fraction` of the Book is behind the position, `remaining` seconds are left (at 1×).
    case inProgress(fraction: Double, remaining: TimeInterval)
    case finished

    public init(_ progress: BookProgress?, duration: TimeInterval) {
        guard let progress else {
            self = .notStarted
            return
        }
        if progress.isFinished {
            self = .finished
        } else if progress.position <= 0 {
            self = .notStarted
        } else {
            let fraction = duration > 0 ? min(progress.position / duration, 1) : 0
            self = .inProgress(fraction: fraction, remaining: max(duration - progress.position, 0))
        }
    }
}

/// One Book's progress for its detail screen: read at once, then following the database.
@Observable
public final class BookProgressModel {
    public private(set) var status: BookProgressStatus

    private let database: AppDatabase
    private let bookID: String
    private let duration: TimeInterval

    public init(database: AppDatabase, bookID: String, duration: TimeInterval) {
        self.database = database
        self.bookID = bookID
        self.duration = duration
        var progress: BookProgress?
        do {
            progress = try database.progress(ofBook: bookID)
        } catch {
            log.error("Couldn't read a Book's progress: \(String(describing: error), privacy: .public)")
        }
        status = BookProgressStatus(progress, duration: duration)
    }

    /// Follows the Book's progress until cancelled.
    public func observe() async {
        do {
            for try await progress in database.progressUpdates(ofBook: bookID) {
                status = BookProgressStatus(progress, duration: duration)
            }
        } catch {
            log.error("Stopped observing a Book's progress: \(String(describing: error), privacy: .public)")
        }
    }
}
