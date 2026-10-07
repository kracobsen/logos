# The database is the single source of truth

Sync, Downloads and Playback write to the local GRDB database and never call back into the UI; each screen's `@MainActor @Observable` model reads by observing the database (`ValueObservation`). We chose this over shared in-memory models because persistence is a primary criterion: what the UI shows is already on disk, so an app kill loses nothing and there is no second copy of state to drift. The one exception is the live playback position, which the player engine exposes directly and writes through to the database on a fixed cadence, because it changes several times a second.

## Considered Options

- **Shared in-memory `@Observable` models at the app root, with the database behind them as persistence.** Rejected: two sources of truth, and background work (downloads, sync) would need explicit wiring to reach the UI.
