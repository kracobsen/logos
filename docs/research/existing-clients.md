# Lessons from existing audiobookshelf iOS clients

Research for [#4](https://github.com/kracobsen/logos/issues/4) (map: [#1](https://github.com/kracobsen/logos/issues/1)). Vocabulary follows `GLOSSARY.md` (Server, Library, Book).

## Sources

All findings come from source code read at a pinned commit, from issue trackers, or from maintainer comments.

| Client | Repo @ commit | Notes |
|---|---|---|
| Official app (Capacitor/Vue + native Swift player) | [advplyr/audiobookshelf-app@7014e04](https://github.com/advplyr/audiobookshelf-app/tree/7014e04e6febcc5fd326e816a57b1065817e85f5) | iOS code is under `ios/App/` |
| ShelfPlayer (native SwiftUI, SwiftData) | [jfrconley/ShelfPlayer@fc46919](https://github.com/jfrconley/ShelfPlayer/tree/fc469193a79cb8612298346cf3921b0351d71cba) | The upstream `rasmuslos/ShelfPlayer` was archived in July 2026 after it was sold, and its source was removed ([README](https://github.com/rasmuslos/ShelfPlayer/blob/55f46edb8dcc265021602d84c662500225c0ae78/README.md)). This fork's HEAD is the author's last upstream commit. |
| AudioBooth (native SwiftUI, SwiftData) | [AudioBooth/AudioBooth@9e7eb54](https://github.com/AudioBooth/AudioBooth/tree/9e7eb546b1e506af77d3f94067f1b0b77381f06d) | The most active open-source native client right now |
| Server (reference for sync semantics) | [advplyr/audiobookshelf@3563d49](https://github.com/advplyr/audiobookshelf/tree/3563d49424d50170324de9236a24c591b6d965e9) | |

Link prefixes used below:
- `APP` = `https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/`
- `SP` = `https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/`
- `AB` = `https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/`
- `SRV` = `https://github.com/advplyr/audiobookshelf/blob/3563d49424d50170324de9236a24c591b6d965e9/`

Other native iOS clients exist, but they are closed source and only have feedback trackers: Plappa, Still, Fable Frog, ShelfPod, Narrata, and absorb (Flutter). They were not studied.

## TL;DR: lessons for Logos

1. **Lost or reverted progress is the most common complaint in every client.** The Server rule is: newest `updatedAt` wins, and some endpoints have no check at all. Every client has broken progress somewhere on top of that rule. Logos needs a small, explicit, tested sync protocol rather than progress writes scattered through the code.
2. **Never block local playback on the network.** ShelfPlayer `await`s `POST /api/items/:id/play` even for downloaded Books, so playback stalls when the Server is slow or unreachable.
3. **Multi-file Books: every client uses one `AVQueuePlayer` with one `AVPlayerItem` per file, plus an offset table.** A seek across files rebuilds the queue. Multi-file mapping bugs ("plays the wrong chapter") are among the bugs users actually hit.
4. **Nobody caches the Library listing locally.** All three clients page `/api/libraries/:id/items` from the Server on every visit. Users with large Libraries report slow cold starts. Logos can beat every existing client here by mirroring the Library into a local store.
5. **SwiftData has bitten both native clients**: duplicate rows, exclusivity crashes, and wipe-on-migration-failure. Choose and test the persistence layer deliberately, and never auto-delete the store.
6. **Set things nobody sets**: `audioTimePitchAlgorithm`, Now Playing that is chapter-relative, an end-of-chapter sleep timer that also works across file boundaries, and per-Book speed.

---

## 1. Multi-file playback and chapters

### What all three do

- **One `AVQueuePlayer` holds one `AVPlayerItem` per audio file.** No client uses `AVComposition` or concatenates files.
  - Official app: [APP `ios/App/Shared/player/AudioPlayer.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/Shared/player/AudioPlayer.swift) L62-124.
  - ShelfPlayer: [SP `ShelfPlayback/LocalAudioEndpoint.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayback/LocalAudioEndpoint.swift) L21, L134, L856-875.
  - AudioBooth: [AB `AudioBooth/AudioBooth/Screens/BookPlayer/AudioPlayer.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Screens/BookPlayer/AudioPlayer.swift) L30, L211-245.
  - AudioBooth keeps a rolling window of 3 queued items and tops it up on each `currentItem` change. The other two enqueue every remaining file.
- **Track model:** each file has `startOffset` and `duration`.
  - Book time = `track.startOffset + player.currentTime()`. The reverse mapping is a linear scan.
  - Official app: `getItemIndexForTime` L174-188 and `getCurrentTime` L517-528.
  - ShelfPlayer: L645-663 and L1180-1187.
  - AudioBooth: L50-54 and L275-292.
- **Cross-file seek:**
  1. Seek within the item if the target is in the current file.
  2. Otherwise call `removeAllItems()`, re-enqueue from the target file, and seek inside it.
  - ShelfPlayer handles the forward case with `advanceToNextItem()` when the target is already queued (L318-393).
  - The official app first seeks the old item to 0, "or we will get jumps to the old position when fading over into a new track" (AudioPlayer.swift L454-456).
  - The official app also guards a race where `currentItem == nil` during a rebuild is mistaken for the end of the Book (`isRebuildingQueue`, L437-474, L814-821).
- **Chapters:** `{id, start, end, title}` in Book time, taken from the Server's `chapters`. Chapters are independent of file boundaries.
  - ShelfPlayer caches the active chapter with a `chapterValidUntil` offset so it doesn't recompute every tick (LocalAudioEndpoint.swift L619-643, L1197-1199).
  - AudioBooth seeks to `chapter.start + 0.1` so it never lands on the previous chapter's boundary ([AB `.../Sheets/ChapterPickerSheetModel.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Screens/BookPlayer/Sheets/ChapterPickerSheetModel.swift) L59, L106-138).
  - In AudioBooth, "previous" restarts the current chapter unless you are less than 2 s into it.
- **Workaround to copy:** ShelfPlayer and AudioBooth both carry the same Apple bug workaround. The xHE-AAC (USAC) decoder bug FB22340742 makes AVPlayer report -11821 "Cannot Decode" at certain positions. Both rebuild the queue 1 s earlier and give up after 10 tries (SP LocalAudioEndpoint.swift L796-854; AB AudioPlayer.swift L297-341).

### Bugs users hit

- **ShelfPlayer 3.2.0 "plays the wrong chapter"** ([rasmuslos/ShelfPlayer#432](https://github.com/rasmuslos/ShelfPlayer/issues/432)). It only affected Books split into one MP3 per chapter: playback started at the right offset but in the first file. It was fixed in 3.2.1. This shows a regression in the offset mapping that only multi-file Books exposed.
- **ShelfPlayer's `didPlayToEndTimeNotification` observer is not filtered by `object:`**, so any item's end advances the track index (LocalAudioEndpoint.swift L1105-1123). This is a fragile pattern.
- **Lesson:** keep the Book-time-to-(file, offset) mapping in one pure, unit-tested value type. Test it against single-file Books, Books with one file per chapter, and Books whose chapters span files.

### Sleep timer (incl. "after X chapters")

- **Official app** ([APP `ios/App/Shared/player/AudioPlayerSleepTimer.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/Shared/player/AudioPlayerSleepTimer.swift) L50-85, L118-122):
  - Chapter-end mode uses `addBoundaryTimeObserver`, but only if the stop point is inside the current file (`guard trackEndTime >= stopAt`).
  - The observer is re-armed only on play or track change.
  - There was a long-standing report that the iOS chapter sleep timer "does not always stop at chapter end" ([#367](https://github.com/advplyr/audiobookshelf-app/issues/367)).
  - "Sleep timer: x chapters" is still an open request ([#202](https://github.com/advplyr/audiobookshelf-app/issues/202)).
- **ShelfPlayer:**
  - Models the timer as `case interval(Date, TimeInterval)` / `case chapters(Int, Int)` ([SP `ShelfPlayerKit/Foundation/Utility/SleepTimerConfiguration.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayerKit/Foundation/Utility/SleepTimerConfiguration.swift)).
  - Counts down when `activeChapterIndex` goes from n to n+1 (LocalAudioEndpoint.swift L48-60, L715-730). A seek that skips ahead does not count.
  - Interval timers fade the volume over the last 10 s, and the deadline shifts while paused (L731-794, L303-306).
  - Per-Book and per-series default timers are persisted.
- **AudioBooth:**
  - Uses the same "observe the chapter index" approach ([AB `.../Sheets/Timer/TimerPickerSheetModel.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Screens/BookPlayer/Sheets/Timer/TimerPickerSheetModel.swift) L61-93). The pause therefore lands up to one 0.5 s tick after the boundary, and there is no fade.
  - The mode broke once in a refactor ([AudioBooth#49](https://github.com/AudioBooth/AudioBooth/issues/49)).
- **Lesson:** "after X chapters" should resolve to an **absolute Book-time stop point**, the end of chapter (current + X − 1).
  - Enforce it with a boundary observer that is re-armed whenever the current item changes, so it also works when the stop point lies in a later file.
  - A fade needs the stop time in advance, which observing the chapter index does not provide.

### Speed

- **All three set `AVPlayer.defaultRate`**, and also `rate` while playing, so `play()` resumes at the chosen speed.
  - Official app: [APP `ios/App/Shared/player/DefaultedAudioPlayerRateManager.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/Shared/player/DefaultedAudioPlayerRateManager.swift) L22-68.
  - ShelfPlayer: LocalAudioEndpoint.swift L253-269.
  - AudioBooth: AudioPlayer.swift L68-77.
- **No client sets `AVPlayerItem.audioTimePitchAlgorithm`**; a grep of all three repos finds nothing.
- **Where the speed is saved differs:**
  - The official app stores one global rate. "Remember playback speed for each audiobook" is an open request with 12 reactions ([#1039](https://github.com/advplyr/audiobookshelf-app/issues/1039)).
  - ShelfPlayer persists the rate per item and resolves it as item, then series, then global ([SP `ShelfPlayback/AudioPlayer.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayback/AudioPlayer.swift) L281-293, L592-602).
  - AudioBooth stores it per Book on its local `MediaProgress`.

### Now Playing / audio session

- **ShelfPlayer and AudioBooth make lock-screen elapsed time and duration chapter-relative.**
  - ShelfPlayer pushes the elapsed time immediately after a seek: "Without this, Now Playing … shows the stale pre-seek elapsed time" (LocalAudioEndpoint.swift L375-380).
  - The official app makes it a setting (AudioPlayer.swift L790-805).
- **Audio session:** all three use `.playback` with `.spokenAudio`. AudioBooth adds the `.longFormAudio` route-sharing policy and calls `setActive` off the main thread ([AB `AudioBooth/AudioBooth/Services/AudioSession.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Services/AudioSession.swift) L5-52).
- **AudioBooth is the most complete on interruptions** ([AB `.../BookPlayerModel.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Screens/BookPlayer/BookPlayerModel.swift) L1191-1296):
  - Interruption with `shouldResume`.
  - `.oldDeviceUnavailable` pauses playback.
  - `mediaServicesWereReset` rebuilds the player. Neither of the other two handles this.
- **Smart rewind on resume** is in all three. The official app scales it by how long playback was paused, from 0 s up to 30 s ([APP `ios/App/Shared/player/util/PlayerTimeUtils.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/Shared/player/util/PlayerTimeUtils.swift) L27-40).

## 2. Progress persistence and sync

### Server semantics every client lives with

- **`POST /api/session/local` and `/api/session/local-all`** (one session, or a batch of offline sessions):
  - The Server **rejects** the session's progress only if `MediaProgress.updatedAt > session.updatedAt`. Otherwise it applies it, so a tie goes to the client.
  - Source: [SRV `server/managers/PlaybackSessionManager.js`](https://github.com/advplyr/audiobookshelf/blob/3563d49424d50170324de9236a24c591b6d965e9/server/managers/PlaybackSessionManager.js) L231-247.
  - On success it overwrites `updatedAt` with the client's `lastUpdate` using raw SQL ([SRV `server/models/MediaProgress.js`](https://github.com/advplyr/audiobookshelf/blob/3563d49424d50170324de9236a24c591b6d965e9/server/models/MediaProgress.js) L252-263). **This makes the device clock authoritative.**
  - `local-all` always returns HTTP 200 with per-session `results[].success` (PlaybackSessionManager.js L103-118).
  - An existing session id is updated in place: `currentTime`, `timeListening` and `updatedAt` are overwritten (L207-220). Clients therefore send cumulative `timeListening` for local sessions.
- **`POST /api/session/:id/sync`** (live Server session) has **no timestamp check**; it sets `currentTime` unconditionally (L373-400).
- **`PATCH /api/me/progress/:libraryItemId`** also has **no timestamp check**, but accepts an optional `lastUpdate` that becomes `updatedAt` ([SRV `server/controllers/MeController.js`](https://github.com/advplyr/audiobookshelf/blob/3563d49424d50170324de9236a24c591b6d965e9/server/controllers/MeController.js) L275-288; MediaProgress.js L252-263).
- **Change notification:** the Server emits the socket event `user_item_progress_updated` when progress changes (PlaybackSessionManager.js L265, L402).

**Consequence:** the Server does only last-writer-wins on timestamps the client supplies. A client that stamps a stale position with "now" silently overwrites newer progress. That is exactly [AudioBooth#393](https://github.com/AudioBooth/AudioBooth/issues/393) (open):

> tapping play starts a local session from the app's cached `MediaProgress` without consulting the server. The session sync then writes that stale position to Audiobookshelf with a fresh `updatedAt`, which replaces newer progress

### How each client does it

**Official app.** The store is Realm.
- **Saving:** a periodic observer saves position every 15 s, and on play/pause ([APP `ios/App/Shared/player/PlayerProgress.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/Shared/player/PlayerProgress.swift) L22-150; AudioPlayer.swift L205-220).
  - The Server push is throttled to 15 s, or 60 s in Low Power Mode.
  - There is no save in `applicationWillTerminate`, so a kill can lose up to 15 s.
- **Offline sync on launch or reconnect** ([APP `ios/App/Shared/util/ApiClient.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/Shared/util/ApiClient.swift) L532-591):
  1. `GET /api/me`. Any Server progress with a newer `lastUpdate` overwrites local progress.
  2. All stored sessions are POSTed to `local-all`. If the HTTP call succeeds, sessions are deleted **without checking per-session `success`**.
- **Server address pitfall:** sessions are filtered by `serverConnectionConfigId`. A Book downloaded under one Server address does not sync when the app is connected through another address ([maintainer comment in #1510](https://github.com/advplyr/audiobookshelf-app/issues/1510); [#1386](https://github.com/advplyr/audiobookshelf-app/issues/1386)).
- **Performance pitfall:** `Database.getPlaybackSession` opens Realm and calls `realm.refresh()` on every call, including Now Playing updates every second. The comment says "working with stale sessions leads to wrong times" ([APP `ios/App/Shared/util/Database.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/Shared/util/Database.swift) L272-276).
- **Bug reports:** the tracker has a dedicated `progress sync` label. Reports of offline progress being overwritten on reconnect are long-running and still open:
  - [#1355](https://github.com/advplyr/audiobookshelf-app/issues/1355), "Save local progress over server", 15 reactions: "Listened offline for 9 hours and when connected to the server, it got reseted".
  - [#1510](https://github.com/advplyr/audiobookshelf-app/issues/1510).
  - [#1397](https://github.com/advplyr/audiobookshelf-app/issues/1397): finishing a Book offline is not synced.
  - Older iOS reports [#828](https://github.com/advplyr/audiobookshelf-app/issues/828) and [#825](https://github.com/advplyr/audiobookshelf-app/issues/825) were fixed. #828 was a stale position captured before backgrounding and then restored after a headphone-button pause. #825 was progress reset when downloading a Book that was already in progress.
  - Several users recover by hand through listening history. A maintainer suggests waiting 5-10 s after reconnecting before pressing play.

**ShelfPlayer.** The store is SwiftData: `PersistedProgress` with a `synchronized/desynchronized/tombstone` status, plus `PersistedPlaybackSession`.
- **Playback start blocks on the network:** when online it always awaits `POST /api/items/:id/play`, even for downloads (LocalAudioEndpoint.swift L476-554).
  - If local and Server positions differ by more than 60 s, it uses `max(local, server)` (L519-527).
  - Users reported playback stuck on a pulsing icon until they reconnected ([#381](https://github.com/rasmuslos/ShelfPlayer/issues/381), where a commenter pins the cause on this `/play` await). There was also [#390](https://github.com/rasmuslos/ShelfPlayer/issues/390), "Offline mode breaks after leaving home network".
- **Every 30 s it writes progress twice** ([SP `ShelfPlayback/PlaybackReporter.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayback/PlaybackReporter.swift) L142-213):
  - session sync or a local session row, and
  - `PATCH /api/me/progress/batch/update`.
- **Reconciliation runs only at launch**, behind a loading screen: `compareDatabase`, last-writer-wins on `lastUpdate` ([SP `ShelfPlayerKit/Persistence/Subsystems/ProgressSubsystem.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayerKit/Persistence/Subsystems/ProgressSubsystem.swift) L214-393). There is no retry driven by network changes.
- **Progress from other devices:** a socket progress update from another device wins unconditionally, unless it is within 7 s of local (L425-451).
- **Defects visible in the source:**
  - `isEqual` is signed: `lhs.distance(to: rhs) < .ulpOfOne` (L630-632). Whenever the Server position is behind local, the pair is treated as "equal" and skipped (L318), so a desynchronized local position that is ahead never gets pushed.
  - `#Unique([\._itemID])` on `PersistedPlaybackSession` ([SP `.../Schema/PersistedPlaybackSession.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayerKit/Persistence/Schema/PersistedPlaybackSession.swift) L15). A second offline session for the same Book overwrites the first.
  - `lastUpdate` is truncated to whole seconds when sent ([SP `ShelfPlayerKit/Network/API+Progress.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayerKit/Network/API+Progress.swift) L38-40).
- **Bug reports:** "book losing all progress occasionally", reset to 0:00, often around offline/online switches or re-auth ([#402](https://github.com/rasmuslos/ShelfPlayer/issues/402), [#339](https://github.com/rasmuslos/ShelfPlayer/issues/339)). The maintainer traced one cause to "a bug that prevents correct progress sync if the progress entity is created by ShelfPlayer". A whole release, 3.2.0, was dedicated to "offline and progress issues" ([#410](https://github.com/rasmuslos/ShelfPlayer/issues/410)).

**AudioBooth.** The store is SwiftData `MediaProgress` with `lastUpdate`.
- **Saving:** position is written to SwiftData every 10 s of movement and on play/pause ([AB `.../BookPlayerModel.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Screens/BookPlayer/BookPlayerModel.swift) L1123-1127, L1299-1371).
- **Sessions for downloaded Books** are local, with ids generated by the client, and sync through `POST /api/session/local`. The design choices:
  - A new session at each day change, with `updatedAt` clamped to the session day.
  - Sync only once 20 s or more of listening is pending.
  - Exponential backoff from 60 s to 16 min.
  - Triggered when the scene becomes active.
  - Source: [AB `AudioBooth/AudioBooth/Services/SessionManager.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Services/SessionManager.swift) L364-495.
  - Because sync needs pending listening time, **a seek while paused or a manual position change is never pushed**.
- **Pulling from the Server:** last-writer-wins on `lastUpdate` ([AB `Models/Sources/Models/MediaProgress.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/Models/Sources/Models/MediaProgress.swift) L155-172).
  - The same sync also **deletes local progress that is missing on the Server** unless that Book is playing or has an unsynced session (L345-357). For an offline-first client this is a hazard.
- **Bug reports:**
  - [#393](https://github.com/AudioBooth/AudioBooth/issues/393): a stale local position overwrites newer Server progress (quoted above).
  - [#345](https://github.com/AudioBooth/AudioBooth/issues/345): "Playback progress repeatedly rolls back to a stale local position". The maintainer: "I did a lot of digging but wasn't able to find the root cause".

### Lessons for Logos (local-first, device authoritative offline)

1. **Use one progress record per Book with a monotonic local `lastUpdate`** that changes **only** when the user actually moves the position (playback, seek, chapter jump, mark finished).
   - Re-opening a Book or creating a session must **not** bump the timestamp.
   - Stamping a stale position with "now" is the root cause of AudioBooth#393.
2. **Keep an explicit outbox** of unsynced progress and finished-state changes, separate from listening sessions.
   - Flush it on reconnect, on foreground, on pause, and from a background task.
   - Delete an outbox entry **only on a per-item success**. The official app deletes even when `results[].success` is false.
   - Seeks and "mark finished" must go through the outbox too. AudioBooth drops them.
3. **Before playing a downloaded Book, decide its start position locally**: use the local record, then reconcile against whatever Server progress was fetched last.
   - Never await the Server to start (ShelfPlayer #381).
   - If newer Server progress arrives while the Book is paused, apply it. If it differs a lot from local, consider prompting the user. #1355 asks for exactly this, Audible-style.
4. **Pick one rule for the "Server newer than device" case and test it.** The candidates are:
   - LWW on the user-action timestamp, which is what the Server enforces anyway;
   - max position, as ShelfPlayer and AudioBooth do when starting a streamed session, which breaks deliberate rewinds;
   - prompting the user.
5. **Never delete local progress because the Server lacks it**, and never auto-wipe the store when it fails to open. AudioBooth deletes its database files if `ModelContainer` creation fails ([AB `Models/Sources/Models/ModelContextProvider.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/Models/Sources/Models/ModelContextProvider.swift) L75-98).
6. **Save the position on every pause, interruption, route change and scene-phase change**, not only on a timer. Crashes and kills are where all three lose up to 10-30 s.
7. **Pick a Server identity that doesn't change.** Key downloads and outbox entries by a stable Server identity, not by its URL. This avoids the official app's "different address, no sync" trap.
8. **Keep a local listening history** (position snapshots). Users of every client recover lost progress by hand through history. AudioBooth records `.sync` history entries when the Server overwrites local progress, which makes these problems debuggable.

## 3. Downloads

- **All three use a background `URLSession`**, with one task per audio file via `/api/items/:id/file/:ino/download`.
  - Each moves the file synchronously inside `didFinishDownloadingTo` and sets `isExcludedFromBackup = true`.
  - Each stores **relative** paths and resolves them against the container at runtime, so the paths survive container UUID changes.
  - Official app: [APP `ios/App/App/plugins/AbsDownloader.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/App/plugins/AbsDownloader.swift) L20-92, L454-488.
  - ShelfPlayer: [SP `ShelfPlayerKit/Persistence/Subsystems/DownloadSubsystem.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayerKit/Persistence/Subsystems/DownloadSubsystem.swift) L53-69, L201-223, L989-1008.
  - AudioBooth: [AB `AudioBooth/AudioBooth/Services/DownloadManager.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Services/DownloadManager.swift) L127-150, L1034-1097, L1304-1310.
- **AudioBooth's is the most robust:**
  - re-attaches in-flight tasks at launch;
  - retries with resume data, treating 5xx/429 as retryable;
  - skips files already present at the expected size;
  - enforces a storage cap.
- **Pitfalls:**
  - The official app's own queue holds tasks it hasn't started yet in memory, so they are lost if the app is killed.
  - ShelfPlayer implements `urlSessionDidFinishEvents` on `AppDelegate`, which is not the session delegate. The stored background completion handler is apparently never called (`App/Lifecycle/AppDelegate.swift` L40-48).
  - Both compute file paths with a `createDirectory` side effect on every access.
- **Offline metadata:** at download time, ShelfPlayer and AudioBooth persist full Book metadata (chapters, tracks with offsets and `ino`, cover, series, authors) so playback and the downloads screen work offline.
- **Bug reports:** downloads that get stuck or can't restart are frequent in the official app ([#1479](https://github.com/advplyr/audiobookshelf-app/issues/1479), [#862](https://github.com/advplyr/audiobookshelf-app/issues/862), [#1970](https://github.com/advplyr/audiobookshelf-app/issues/1970)). So is "Chapters are not updated after download" ([#525](https://github.com/advplyr/audiobookshelf-app/issues/525)).

## 4. Library caching for fast browsing

- **No client keeps a local mirror of the Library.**
  - Official app: a sparse `entities` array with pages loaded on scroll from `/api/libraries/:id/items?limit&page&minified=1`. Covers rely on WebView HTTP caching with a `?ts=updatedAt` cache-buster ([APP `components/bookshelf/LazyBookshelf.vue`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/components/bookshelf/LazyBookshelf.vue) L170-253).
  - ShelfPlayer: offset paging of 100 items, an in-memory TTL `NSCache` of 120 responses, and `URLCache` disabled. There is also a JSON disk cache for item details ([SP `App/Utility/LazyLoadHelper.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/App/Utility/LazyLoadHelper.swift) L19-231; [SP `ShelfPlayerKit/Network/Client/APIClient.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayerKit/Network/Client/APIClient.swift) L26-59, L281-329).
  - AudioBooth: 100 items per page, in memory only. A failed page-0 load leaves the list empty. Only Home and filter data are cached, as JSON in UserDefaults ([AB `.../Screens/Library/Library/LibraryPageModel.swift`](https://github.com/AudioBooth/AudioBooth/blob/9e7eb546b1e506af77d3f94067f1b0b77381f06d/AudioBooth/AudioBooth/Screens/Library/Library/LibraryPageModel.swift) L17, L326-397).
- **Users feel it:**
  - ShelfPlayer [#281](https://github.com/rasmuslos/ShelfPlayer/issues/281): 17 s to load Home; Libraries of about 300 and 1600 items were reported as slow. The maintainer: "In version 3.0.0, there are a lot more requests to individual items … there is indeed an in-memory cache. I will look into adding a disk cache".
  - [#316](https://github.com/rasmuslos/ShelfPlayer/issues/316) "Bad performance when rendering large libraries" and [#392](https://github.com/rasmuslos/ShelfPlayer/issues/392) "Improve handling of large libraries" are still open.
  - AudioBooth [#75](https://github.com/AudioBooth/AudioBooth/issues/75): search typing lagged on a 600-Book Library because each keystroke blocked on a Server query; this was mitigated with debouncing. [#338](https://github.com/AudioBooth/AudioBooth/issues/338): tabs "reload fully on every visit".
- **Images:**
  - ShelfPlayer's `ImageLoader` actor: in-flight dedupe, then an `NSCache`, then an on-disk cache per width, then the downloaded cover. Its in-flight `Task` dictionary is never evicted ([SP `ShelfPlayerKit/Human Interface/Image/ImageLoader.swift`](https://github.com/jfrconley/ShelfPlayer/blob/fc469193a79cb8612298346cf3921b0351d71cba/ShelfPlayerKit/Human%20Interface/Image/ImageLoader.swift) L15-136).
  - AudioBooth uses Nuke with a disk `DataCache`.
  - "Cache book covers" is an open request on the official app ([#907](https://github.com/advplyr/audiobookshelf-app/issues/907)).
- **What the Server offers for incremental refresh:**
  - **There is no "changed since" endpoint.** `getLibraryItems` takes only `limit`, `page`, `sort`, `filter`, `minified`, `collapseseries` and `include` ([SRV `server/controllers/LibraryController.js`](https://github.com/advplyr/audiobookshelf/blob/3563d49424d50170324de9236a24c591b6d965e9/server/controllers/LibraryController.js) L604-625).
  - The socket does emit `item_added`/`items_added`, `item_updated`/`items_updated` and `item_removed` ([SRV `server/scanner/LibraryScanner.js`](https://github.com/advplyr/audiobookshelf/blob/3563d49424d50170324de9236a24c591b6d965e9/server/scanner/LibraryScanner.js) L271-279, L631; [SRV `server/controllers/LibraryItemController.js`](https://github.com/advplyr/audiobookshelf/blob/3563d49424d50170324de9236a24c591b6d965e9/server/controllers/LibraryItemController.js) L280+; [SRV `server/routers/ApiRouter.js`](https://github.com/advplyr/audiobookshelf/blob/3563d49424d50170324de9236a24c591b6d965e9/server/routers/ApiRouter.js) L403).
- **Lesson:** for about 1000 Books, mirror the whole minified Library into the local store.
  - Do it in a few large pages, which are cheap, and keep each item's `updatedAt`.
  - Browse, sort, filter, search and Series navigation run entirely against the local store.
  - Refresh in the background, using a full re-page with a diff by `updatedAt`, socket events, or both.
  - Use a disk-backed cover cache keyed by item id and `updatedAt`, and use the downloaded cover for downloaded Books.

## 5. Things to avoid (consolidated)

- **Blocking local playback on the network.** ShelfPlayer awaits `/play`.
- **Stamping "now" on a position the user didn't just produce.** This is AudioBooth#393.
- **Deleting queued syncs on HTTP success while ignoring per-item results.** The official app does this with `local-all`.
- **Running sync only at launch.** ShelfPlayer does this behind a blocking "syncing" screen.
- **Comparisons and unique constraints that silently drop data:**
  - ShelfPlayer's signed `isEqual`;
  - `#Unique` on session item ids;
  - whole-second `lastUpdate`.
- **Pruning local progress because the Server doesn't have it**, and wiping the database when it fails to open. AudioBooth does both.
- **SwiftData concurrency hazards:**
  - AudioBooth crashed with an exclusivity violation inside SwiftData on iOS 17 ([#349](https://github.com/AudioBooth/AudioBooth/issues/349)).
  - ShelfPlayer needed explicit dedupe because "never mutate the ModelContext from several concurrent tasks at once" (ProgressSubsystem.swift L70-84).
  - ShelfPlayer's 2.x crashes were blamed on non-thread-safe shared arrays and led to a full backend rewrite ([#189](https://github.com/rasmuslos/ShelfPlayer/issues/189)). The author rewrote the app twice in total because of architecture problems (README).
  - Whatever store Logos uses, give it a single writer, such as one actor.
- **Re-fetching per item to render lists.** This caused ShelfPlayer 3.0's 17 s Home load.
- **Hot-path database refreshes.** The official app opens Realm and refreshes it every second.
- **Unbounded logs:** the official app had to wipe a log store that was "freezing the app on load/clear" ([APP `ios/App/App/AppDelegate.swift`](https://github.com/advplyr/audiobookshelf-app/blob/7014e04e6febcc5fd326e816a57b1065817e85f5/ios/App/App/AppDelegate.swift) L74-77). Still, a bounded on-device log exported from settings is how every maintainer debugs progress bugs; ShelfPlayer and AudioBooth both have one.

## Open questions surfaced

- **Conflict rule when the Server is newer than the device** (another device or the web player advanced the Book). The options are LWW on user-action time, max position, or a prompt. The Server's rule plus the map's "device authoritative while offline" settles the offline case. It does not settle the case of reconnecting to find newer Server progress.
- **Listening sessions vs. a pure progress PATCH.** Logos could report progress only with `PATCH /api/me/progress` plus `lastUpdate`, or also create `/api/session/local` sessions. Sessions are what populate the Server's listening stats and history; the PATCH is simpler but has no timestamp guard on the Server side.
- **Choice of persistence layer.** SwiftData was the source of crashes and duplicates in both native clients. The alternatives are GRDB/SQLite or SwiftData with a strict single-writer actor.
