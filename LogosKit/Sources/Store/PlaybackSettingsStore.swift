import Domain
import Foundation
import GRDB

extension AppDatabase {
    /// Migration `v6-playback-settings`: the speed and the skip intervals, in one row.
    static func registerPlaybackSettingsMigration(in migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v6-playback-settings") { db in
            // One row at most (id is always 1); no row means the defaults.
            try db.create(table: "playbackSettings") { table in
                table.primaryKey("id", .integer).check { $0 == 1 }
                table.column("speed", .double).notNull().defaults(to: PlaybackSettings.default.speed)
                table.column("skipBack", .integer).notNull().defaults(to: PlaybackSettings.default.skipBack.rawValue)
                table.column("skipForward", .integer).notNull()
                    .defaults(to: PlaybackSettings.default.skipForward.rawValue)
            }
        }
    }

    /// The speed and the skip intervals.
    public func playbackSettings() throws -> PlaybackSettings {
        try pool.read(Self.fetchPlaybackSettings)
    }

    /// The settings now, then again after each change.
    public func playbackSettingsUpdates() -> AsyncThrowingStream<PlaybackSettings, any Error> {
        observe(Self.fetchPlaybackSettings)
    }

    /// The global speed, stored as the nearest speed there is (``PlaybackSpeed/normalized(_:)``).
    public func setPlaybackSpeed(_ speed: Double) throws {
        try setPlaybackSettingsColumn("speed", to: PlaybackSpeed.normalized(speed))
    }

    public func setSkipBack(_ interval: SkipInterval) throws {
        try setPlaybackSettingsColumn("skipBack", to: interval.rawValue)
    }

    public func setSkipForward(_ interval: SkipInterval) throws {
        try setPlaybackSettingsColumn("skipForward", to: interval.rawValue)
    }

    private func setPlaybackSettingsColumn(_ column: String, to value: some DatabaseValueConvertible & Sendable)
        throws
    {
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO playbackSettings (id, \(column)) VALUES (1, ?)
                    ON CONFLICT(id) DO UPDATE SET \(column) = excluded.\(column)
                    """,
                arguments: [value])
        }
    }

    @Sendable static func fetchPlaybackSettings(_ db: Database) throws -> PlaybackSettings {
        guard let row = try Row.fetchOne(db, sql: "SELECT speed, skipBack, skipForward FROM playbackSettings")
        else { return .default }
        let defaults = PlaybackSettings.default
        return PlaybackSettings(
            speed: row["speed"],
            skipBack: SkipInterval(rawValue: row["skipBack"]) ?? defaults.skipBack,
            skipForward: SkipInterval(rawValue: row["skipForward"]) ?? defaults.skipForward)
    }
}
