# iOS 27 platform choices: persistence, downloads, playback

Research for [#3](https://github.com/kracobsen/logos/issues/3). Researched 2026-10-01 against Apple developer documentation (iOS 27 / Xcode 27 era), WWDC26 and WWDC25 sessions, Swift Evolution, GRDB sources, SQLite docs and the audiobookshelf sources. This file gives inputs for decisions. It does not make them; the grilling tickets do.

Context (from the map, #1): iOS 27 only, Swift 6 strict concurrency, SwiftUI. One Server, one Library of about 1000 Books. Only downloaded Books play. Priorities are performance/responsiveness and persistence: never lose the playback position, and the OS must never evict downloads.

Legend: **[verified]** means checked against a primary source cited inline. **[unverified]** means I could not confirm it at the source, so treat it as a lead.

---

## 1. Local store for the Library catalogue and playback state

### What's current

- **SwiftData (iOS 27 additions)** [verified]. From [SwiftData updates](https://developer.apple.com/documentation/updates/swiftdata) and [WWDC26 "What's new in SwiftData"](https://developer.apple.com/videos/play/wwdc2026/274/):
  - `@Query(..., sectionBy:)` gives sectioned queries, read through `_query.sections`.
  - `@Attribute(.codable)` stores a Codable type as an opaque blob. The blob can't be used in predicates or sorts and isn't migrated.
  - `ResultsObserver` observes fetch results outside SwiftUI, built on Swift Observation (`withContinuousObservation`).
  - `HistoryObserver` observes persistent-history transactions and can filter by author. It's meant for syncing to an external system, which is useful for "sync progress to the Server".
  - Enum predicates and `Predicate(all:)`/`Predicate(any:)` compound predicates also arrived (per [Michael Tsai's roundup](https://mjtsai.com/blog/2026/06/23/swiftdata-in-appleos-27/). I didn't find these on the Apple updates page itself).
  - Earlier releases added `#Index` and `#Unique` (iOS 18) and model inheritance (iOS 26).
- **SwiftData pain points that may still apply** [unverified for iOS 27]:
  - `@Model` types aren't `Sendable`. You pass a `PersistentIdentifier` across actors and re-fetch on the other side ([Apple forums 762178](https://developer.apple.com/forums/thread/762178), [775661](https://developer.apple.com/forums/thread/775661)).
  - `@ModelActor` work has been observed running on the main thread, depending on where the actor is created ([forums 770405](https://developer.apple.com/forums/thread/770405)).
  - Tsai's iOS 27 roundup still lists "ModelActor sometimes executing on main thread" and "`propertiesToFetch` doesn't work as intended".
  - The WWDC26 session makes no performance claims and doesn't cover background contexts.
- **GRDB** [verified]:
  - The current release is [v7.11.1 (2026-06-18)](https://github.com/groue/GRDB.swift/releases). It needs swift-tools 6.1 (Package.swift).
  - GRDB 7 is built for Swift 6 concurrency. Records are `Sendable` structs, and it has async `read`/`write` and `ValueObservation.values(in:)` async sequences ([Swift Concurrency guide](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/SwiftConcurrency.md)).
  - `DatabasePool` uses WAL with concurrent reads and serialized writes. The rule is one pool per file ([Concurrency guide](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md)).
  - Schema changes use the explicit `DatabaseMigrator`.
  - Benchmarks from the [GRDB wiki](https://github.com/groue/GRDB.swift/wiki/Performance) (GRDB 7.0, Xcode 16.2, M1 Pro): record fetch ≈ raw SQLite, and change-tracked fetch takes 0.24 s for GRDB vs 0.45 s for Core Data. **SwiftData isn't in that benchmark.** I found no first-party SwiftData-vs-GRDB benchmark. Secondary sites quote "~20x" figures that I couldn't trace to a source, so this file doesn't use them.
- **SQLiteData (Point-Free)** [verified]:
  - Built on GRDB. It offers `@FetchAll`/`@FetchOne` as SwiftUI-observing wrappers, the analogue of `@Query`, plus optional CloudKit sync ([repo](https://github.com/pointfreeco/sqlite-data)).
  - It's a middle ground: SwiftData-like view ergonomics on top of SQL.
- **Swift 6.2+ default MainActor isolation** [verified]:
  - [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md) is implemented in Swift 6.2. Xcode's new-project template turns on `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
  - Database record types and the persistence layer must then be explicitly `nonisolated`, or live in a separate module without that default. Otherwise they can't be used from GRDB's background queues. GRDB's docs don't discuss this setting.
- **Durability** [verified]:
  - [SQLite PRAGMA synchronous](https://www.sqlite.org/pragma.html): "Transactions are durable across application crashes regardless of the synchronous setting." In WAL mode with `synchronous=NORMAL`, a commit "might roll back following a power loss or system crash". `FULL` is fully ACID in WAL.
  - So an app kill or crash never loses a committed position. Only OS-level crashes or power loss can, and only with NORMAL. I didn't verify which default GRDB or Apple's SQLite build uses. Set it explicitly.

### Trade-offs for Logos

| | SwiftData | GRDB (+ optionally SQLiteData) |
|---|---|---|
| ~1000-Book list | Fine at this size; `@Query` + `sectionBy` handles author/series sections | Fine; hand-written SQL, `ValueObservation` |
| Concurrency (Swift 6) | Non-Sendable models; ID hand-off; reported ModelActor main-thread issues | Sendable value records; explicit async read/write; well-defined |
| Migration | `VersionedSchema`/`SchemaMigrationPlan` (lightweight + custom) | Explicit, ordered `DatabaseMigrator` |
| Reliability / control | Opaque Core Data stack; can't tune pragmas | Full control (WAL, `synchronous`, indexes, transactions) |
| Sync to Server | `HistoryObserver` (iOS 27) is purpose-built for outbound sync | Build an outbox table, or observe with `ValueObservation`/`TransactionObserver` |
| Dependencies | None (first-party) | Third-party SPM package(s) |

**Leading recommendation:** use GRDB (raw or via SQLiteData) with a `DatabasePool` in Application Support. Store playback position as an explicit write-through row. The deciding criteria are persistence control (explicit transactions and pragmas) and predictable Swift 6 concurrency, and those favour GRDB. SwiftData is a reasonable fallback if a first-party-only rule wins: iOS 27's `ResultsObserver`/`HistoryObserver` close real gaps. If SwiftData is chosen, use a prototype to check its threading behaviour on iOS 27.

---

## 2. Background downloads of multi-file Books

### What's current [verified unless marked]

- **Background `URLSession`** ([Downloading files in the background](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background), [`background(withIdentifier:)`](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:))):
  - Transfers run in a separate system process and continue while the app is suspended or terminated by the system.
  - **If the user force-quits the app, all of that session's background transfers are cancelled**, and the app isn't relaunched until the user opens it.
  - Use one session with a fixed identifier and recreate it at launch. Implement `application(_:handleEventsForBackgroundURLSession:completionHandler:)` and call the stored handler in `urlSessionDidFinishEvents`.
  - The downloaded file only exists until `didFinishDownloadingTo` returns. Move it synchronously inside that callback.
  - Redirects are always followed. A delegate is required.
  - A rate limiter delays tasks started from the background, and the delay grows on each relaunch. **Enqueue all of a Book's files at once** in the foreground rather than chaining them.
  - `isDiscretionary` applies only to tasks started in the foreground. Tasks started in the background are always discretionary. Leave it `false` for user-initiated Downloads.
- **Resume** ([Pausing and resuming downloads](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads), [`cancel(byProducingResumeData:)`](https://developer.apple.com/documentation/foundation/urlsessiondownloadtask/cancel(byproducingresumedata:))):
  - Background sessions resume automatically after transient failures.
  - Manual resume uses `NSURLSessionDownloadTaskResumeData` from the error, or `cancel(byProducingResumeData:)`.
  - Resume requires GET, an unchanged resource, `ETag` or `Last-Modified`, byte-range support, and that the OS hasn't deleted the temp file.
- **audiobookshelf side**:
  - Per-file download is `GET /api/items/:id/file/:fileid/download`, served by Express `res.download` ([ApiRouter.js](https://github.com/advplyr/audiobookshelf/blob/master/server/routers/ApiRouter.js), [LibraryItemController.js](https://github.com/advplyr/audiobookshelf/blob/master/server/controllers/LibraryItemController.js)).
  - Express's `send` normally emits `ETag`/`Last-Modified` and honours `Range`, so per-file downloads should be resumable [unverified end-to-end; a reverse proxy can strip these].
  - `GET /api/items/:id/download` streams a whole-Book zip, which is likely not resumable. Prefer per-file tasks.
- **Auth caveat**:
  - audiobookshelf ≥ 2.26 uses short-lived JWT access tokens with refresh tokens ([discussion #4460](https://github.com/advplyr/audiobookshelf/discussions/4460)). Lifetimes are configurable; sources disagree on the defaults (1 h vs 12 h).
  - Background tasks carry the header captured when the task was created. A long queue may start tasks after the token expires and fail with 401. A `?token=` query token has the same problem.
- **Storage location and eviction** ([Optimizing your app's data for iCloud backup](https://developer.apple.com/documentation/foundation/optimizing-your-app-s-data-for-icloud-backup)):
  - `tmp/` and `Library/Caches/` are purged by the system. **Never put Downloads there.**
  - Put Downloads under `Library/Application Support/` or `Library/<bundle-id>/` and set `isExcludedFromBackup = true` on the containing directory. Apple's own example is "downloads … for offline viewing … exclude those files". Re-apply it after file operations, which can reset it.
  - "Offload Unused Apps" keeps documents and data ([Apple Support](https://support.apple.com/guide/iphone/manage-storage-on-iphone-iph47c931112/ios)).
- **Data protection** ([Encrypting your app's files](https://developer.apple.com/documentation/uikit/encrypting-your-app-s-files)):
  - The default class is *complete until first user authentication*. Keep that default, not `.complete`, for audio files and the database.
  - Background download completions and lock-screen playback need access while the device is locked.
- **`BGContinuedProcessingTask`** (iOS 26, [WWDC25 "Finish tasks in the background"](https://developer.apple.com/videos/play/wwdc2025/227/)) is for user-initiated, visible-progress *processing*. Network transfers belong to the background URLSession. It's not needed here.

**Leading recommendation:** a single background `URLSession`, one download task per audio file, all enqueued from the foreground. Persist a per-file Download state in the store, keyed by `taskIdentifier`/task description, and reconcile with `getAllTasks()` at launch. Move each file into an excluded-from-backup directory under Application Support. A Book counts as "downloaded" only when every file is present and its size has been verified. Leave the token-expiry handling to the sign-in ticket.

---

## 3. Playing a multi-file Book as one timeline

### Options [verified unless marked]

- **AVQueuePlayer** with one `AVPlayerItem` per file ([docs](https://developer.apple.com/documentation/avfoundation/avqueueplayer)):
  - The app maps global Book time to (file index, offset) itself. Seeking backwards across files means rebuilding the queue.
  - This is what the official audiobookshelf iOS app does ([AudioPlayer.swift](https://github.com/advplyr/audiobookshelf-app/blob/master/ios/App/Shared/player/AudioPlayer.swift): `AVQueuePlayer`, `seek(..., toleranceBefore: .zero, toleranceAfter: .zero)`, `.playback`/`.spokenAudio`).
  - Gaps at file boundaries usually come from the encoding, not the player. An Apple forums report concluded that "AVQueuePlayer can do gapless playback just fine as long as your files are actually gapless" ([thread 111413](https://developer.apple.com/forums/thread/111413), user answer, not Apple staff).
  - AAC priming is trimmed by the system per [TN2258](https://developer.apple.com/library/ios/technotes/tn2258/_index.html). MP3 has no standard gapless metadata.
- **AVMutableComposition**: insert each file's audio track back to back with `insertTimeRange(_:of:at:)` ([docs](https://developer.apple.com/documentation/avfoundation/avmutablecomposition)), then play one `AVPlayerItem`.
  - The result is a single timeline: `seek(to:)` addresses Book time directly, rate stays on one item, and chapter times from the Server map one to one.
  - **Open each `AVURLAsset` with `AVURLAssetPreferPreciseDurationAndTimingKey = true`**. Apple says precise access "is typically desirable" when inserting into a composition, and that formats other than QuickTime/MPEG-4 (such as MP3) need extra parsing ([docs](https://developer.apple.com/documentation/avfoundation/avurlassetpreferprecisedurationandtimingkey)). This costs load time for long MP3s; measure it.
  - Whether boundaries are sample-accurate and silent inside a composition is [unverified]. Prototype it with real Library files.
- **AVAudioEngine + AVAudioPlayerNode + AVAudioUnitTimePitch**:
  - `scheduleSegment`/`scheduleFile` with `when: nil` plays "immediately following" the previous segment, which is true sample-level chaining ([docs](https://developer.apple.com/documentation/avfaudio/avaudioplayernode)). Rate and pitch are independent ([AVAudioUnitTimePitch](https://developer.apple.com/documentation/avfaudio/avaudiounittimepitch)).
  - The cost is a lot more code. You own the timeline (seek = `stop()` + reschedule; `stop()` resets player time to 0), interruptions, route changes and Now Playing elapsed time.
  - Don't stop the node inside a completion handler, because it can deadlock.
- **Rate control** (for any AVPlayer):
  - Set `defaultRate` (iOS 16+) so `play()` resumes at the chosen speed. Don't set `rate = 1` to start ([docs](https://developer.apple.com/documentation/avfoundation/avplayer/defaultrate)).
  - Pitch algorithms: `.timeDomain` is "suitable for voice" and cheaper, `.spectral` is highest quality and costliest, and `.varispeed` has no pitch correction. All cover 1/32–32× ([AVAudioTimePitchAlgorithm](https://developer.apple.com/documentation/avfoundation/avaudiotimepitchalgorithm)). Set it on the `AVPlayerItem` with `audioTimePitchAlgorithm`.
- **Chapters**:
  - Embedded chapters load with `AVAsset.loadChapterMetadataGroups(withTitleLocale:containingItemsWithCommonKeys:)` (iOS 15+).
  - For Logos, the Server's chapter list is the cross-format source of truth, and it uses global Book time. That fits a single timeline.
- **Observation**: for elapsed time, use `addPeriodicTimeObserver`/`addBoundaryTimeObserver`, not KVO ([AVPlayer](https://developer.apple.com/documentation/avfoundation/avplayer)). Boundary observers fit "sleep after X chapters".

**Leading recommendation:** `AVPlayer` with an `AVMutableComposition` built from the downloaded files (precise-timing assets), `defaultRate`, and `.timeDomain` (or `.spectral` if quality at 1.5–2× matters). This gives one Book timeline, which makes seeking, chapters, persisted position and the sleep timer simple. Keep AVQueuePlayer as the fallback, since it's proven by the official app. Use AVAudioEngine only if a prototype shows audible gaps or seek drift with the composition. **Prototype first**, with one multi-MP3 Book and one single-file M4B Book.

---

## 4. Now Playing, remote commands, audio session, interruptions

### What's new in iOS 27 [verified]

- **The new Now Playing framework** (`import NowPlaying`, iOS 27+) ([framework docs](https://developer.apple.com/documentation/nowplaying), [Publishing media sessions](https://developer.apple.com/documentation/nowplaying/publishing-media-sessions), [WWDC26 "Meet the Now Playing framework"](https://developer.apple.com/videos/play/wwdc2026/312/)):
  - You make an `@Observable @MainActor` model conform to `MediaSessionRepresentable`, with `id`, `content`, `playbackSnapshot` and `commands`, and register it with `MediaSession(model)`. Then call `requestToBecomeApplicationPrimary()`, or `requestToBecomeSystemPrimary()`, which only works from the foreground.
  - **`BookContent`** (title, authorName, narratorName, duration, artwork, `chapter`) is specifically for audiobooks ([BookContent](https://developer.apple.com/documentation/nowplaying/bookcontent)).
  - `MediaPlaybackSnapshot` (state, elapsedTime, timestamp) lets the system extrapolate elapsed time between updates.
  - `MediaCommand` factories include `play`, `pause`, `togglePlayPause`, `stop`, `skipForward/Backward(preferredIntervals:)`, `seekToPosition`, `seekForward/Backward`, `changePlaybackRate(supported:)`, `next/previous` and `.enabled(_:)` ([MediaCommand](https://developer.apple.com/documentation/nowplaying/mediacommand)).
  - **Apple: "Don't mix the Now Playing framework with the `MPNowPlayingInfoCenter` and `MPRemoteCommandCenter` APIs … Doing so results in undefined behavior."**
  - The MediaPlayer APIs aren't marked deprecated in the documentation metadata.
- **Audio session lifecycle notifications (iOS 27)** ([Handling audio interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions)):
  - `AVAudioSession.didBecomeActiveNotification`, `didBecomeInactiveNotification` (with a `DeactivationContext` saying whether the app or the system caused it) and `resumptionRecommendationNotification` (`.shouldResume`/`.shouldNotResume`). All are iOS 27.0+ and posted on the main queue.
  - There are also typed `MainActorMessage` variants.
  - Apple says to adopt these for new code because they "don't get out of sync when the system can't deliver an end event". The article says the legacy `interruptionNotification` is deprecated in later releases, though the symbol page doesn't yet show a deprecation.
  - `AVPlayer` pauses automatically on interruption. Observe `timeControlStatus` to update the UI.
- **Session configuration**:
  - Category `.playback` with mode `.spokenAudio`, which makes the app *pause rather than duck* when another app plays a spoken prompt such as navigation ([docs](https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/spokenaudio)).
  - Optionally use route-sharing policy `.longFormAudio`, which shares output with Music and Podcasts ([docs](https://developer.apple.com/documentation/avfaudio/avaudiosession/routesharingpolicy-swift.enum/longformaudio)).
  - Observe `routeChangeNotification` (posted on a secondary thread) for headphone-unplug pauses.
  - Persist the position on every pause, deactivation or route-change pause.
- [unverified] One report says that on the iOS 27 betas, opening Notification Center pauses AVPlayer playback (seen in [Apple forums AVFoundation tag](https://developer.apple.com/forums/tags/avfoundation?page=2) search results). Re-test on the release build.

**Leading recommendation:** use the Now Playing framework with `BookContent` and `MediaSession`, since the app is iOS 27 only. Don't touch `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter`. Use `.playback` + `.spokenAudio` and the iOS 27 lifecycle notifications for interruptions. Save the position on every deactivation or pause.

---

## 5. Observation and SwiftUI list performance (~1000 Books)

[verified]

- `@Observable` updates a view only when properties its `body` actually reads change. `ObservableObject` updates on any `@Published` change ([Migrating to Observable](https://developer.apple.com/documentation/swiftui/migrating-from-the-observable-object-protocol-to-the-observable-macro)). Keep row views reading only their own Book's fields.
- **WWDC26 SwiftUI** ([What's new in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/269/)):
  - `@State` holding an `@Observable` is now initialized lazily, once per view lifetime. This is back-deployed to iOS 17.
  - `ContentBuilder` unifies result builders and improves type-check time.
  - `AsyncImage` now uses HTTP caching and accepts a custom `URLRequest`/`URLSession`. Useful for covers, though for offline-first you'll likely want your own on-disk cover cache.
  - Reorderable APIs work on any container.
  - (Secondary sources claim up to 2× faster layout [unverified at source].)
- **WWDC26 "Dive into lazy stacks and scrolling"** ([session 321](https://developer.apple.com/videos/play/wwdc2026/321/)):
  - Lazy stacks prefetch rows across frames and estimate off-screen heights.
  - Keep one row view to one subview. Filter at the query level, not with `if` in the row body.
  - Set up state in `init`, not `onAppear`, because prefetch work is otherwise thrown away.
  - Keep durable state in the parent, since row `@State` is dropped when a row scrolls away.
  - Use fixed or bounded row heights. Use `onScrollTargetVisibilityChange` instead of content-offset maths, and `ScrollPosition.scrollTo(id:)` for jumping (for example to a letter or Series).
  - The session gives no numbers.
- **Instruments**: WWDC26 ["Profile, fix, and verify: Improve app responsiveness with Instruments"](https://developer.apple.com/videos/play/wwdc2026/268/) (not reviewed in depth).
- **For ~1000 rows**: `List` or `LazyVStack` with stable `id`s (the Server's Book id) and lightweight value-type row models (Sendable structs from GRDB, or `@Model` with only the displayed fields read) is well within normal SwiftUI territory. The bigger risk is cover-image decoding, so downsample and cache thumbnails off the main actor.

**Leading recommendation:** use `List` (or `LazyVStack` for custom layout) over value-type rows from the store's observation, sectioned in the query. Use a local thumbnail cache. Profile with the SwiftUI instrument early, against a real 1000-Book Library.

---

## Not verified / gaps

- No first-party or reproducible benchmark of SwiftData vs GRDB on iOS 27.
- Whether iOS 27 fixed SwiftData's `ModelActor` main-thread behaviour.
- Whether sample-accurate, silent file boundaries hold inside `AVMutableComposition` for MP3 and M4A/M4B audiobook parts.
- The default `synchronous` pragma for GRDB on Apple's SQLite.
- End-to-end resumability (ETag/Range) of audiobookshelf per-file downloads behind typical reverse proxies.
- How the iOS 27 Now Playing framework behaves with AVPlayer in the background (for example if the app must already be playing for commands to arrive), beyond what the docs and the session say.
- The Notification Center pause regression on the iOS 27 betas.
