# audiobookshelf API surface for a Logos v1 client

Research for [#2](https://github.com/kracobsen/logos/issues/2). Question: what does the current audiobookshelf Server API give a Books-only, local-playback client, and where does behaviour differ by Server version?

**Sources and trust.** Everything here comes from the Server source at tag
[`v2.37.1`](https://github.com/advplyr/audiobookshelf/tree/v2.37.1) (commit `3563d49`, released 2026-09-29, the latest release when this was written), from the GitHub release notes, and from the maintainer's auth announcement
([discussion #4460](https://github.com/advplyr/audiobookshelf/discussions/4460)).
The official API docs at [api.audiobookshelf.org](https://api.audiobookshelf.org/) say about themselves: *"These API docs are out-of-date and are no longer maintained."* Treat them as a rough map only. The repo also ships an OpenAPI spec at [`docs/openapi.json`](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/docs/openapi.json), but it covers only part of the API. The source is the authority.

Links below use `S/` as shorthand for `https://github.com/advplyr/audiobookshelf/blob/v2.37.1/`.

Vocabulary follows `GLOSSARY.md`. The Server calls a Book a "library item" (`libraryItem`) whose `media` is a `book`. Most endpoints take the **library item id**, not the book (media) id. Logos should store both.

---

## 1. Base URL and discovery

- **Base path.** All routes are mounted under `ROUTER_BASE_PATH` (default `/audiobookshelf`). Requests without that prefix are rewritten to include it, so `https://host/api/...` and `https://host/audiobookshelf/api/...` both work ([S/index.js#L50](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/index.js#L50), [S/server/Server.js#L307-L317](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Server.js#L307-L317)).
- **`GET /status`** (no auth) returns `{ app: "audiobookshelf", serverVersion, isInit, language, authMethods, authFormData }` ([S/server/Server.js#L368-L384](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Server.js#L368-L384)). Use it at sign-in to check the URL and to read `serverVersion` for version gating. `GET /ping` and `GET /healthcheck` also exist.
- **Library choice.** `GET /api/libraries` lists libraries ([S/server/routers/ApiRouter.js#L70](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/routers/ApiRouter.js#L70)). The login payload includes `userDefaultLibraryId` ([S/server/Auth.js#L96-L105](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Auth.js#L96-L105)). Keep only libraries with `mediaType: "book"`.

## 2. Authentication

### Current system (Server v2.26.0 and later)

v2.26.0 added *"JWT authentication with refresh tokens to replace old authentication system"*, plus API keys, a Session model and an auth rate limiter ([v2.26.0 release](https://github.com/advplyr/audiobookshelf/releases/tag/v2.26.0)).

| Step | Request | Notes |
|---|---|---|
| Login | `POST /login` with JSON `{username, password}` and header **`x-return-tokens: true`** | Without the header, the refresh token goes only into an httpOnly cookie and `user.refreshToken` is `null`. With it, the response has `user.accessToken` and `user.refreshToken` ([S/server/Auth.js#L288-L329](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Auth.js#L288-L329)). |
| Authenticated calls | `Authorization: Bearer <accessToken>`, or `?token=<accessToken>` in the query string | Both extractors are registered ([S/server/Auth.js#L126](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Auth.js#L126)). |
| Refresh | `POST /auth/refresh` with header **`x-refresh-token: <refreshToken>`** | When the header is used, the new refresh token is returned in the body. The response has the same shape as login, with new `user.accessToken` and `user.refreshToken` ([S/server/Auth.js#L331-L360](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Auth.js#L331-L360)). |
| Re-validate a stored token | `POST /api/authorize` | Returns the login payload (user, `userDefaultLibraryId`, serverSettings) for the current bearer token ([S/server/controllers/MiscController.js#L277-L288](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/MiscController.js#L277-L288)). |
| Logout | `POST /logout` with `x-refresh-token` | Invalidates that refresh token. `?allDevices=1` (v2.36.0+) ends all of the user's sessions ([S/server/Auth.js#L486-L501](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Auth.js#L486-L501), [v2.36.0](https://github.com/advplyr/audiobookshelf/releases/tag/v2.36.0)). |

**Token lifetimes.** These are configurable by whoever runs the Server, so Logos must not hard-code them.

| Server version | Access token | Refresh token | Grace period for a rotated refresh token |
|---|---|---|---|
| v2.26.0 to v2.30.x | 12 h | 7 d | none |
| v2.31.0+ | **1 h** | **30 d** | none |
| v2.35.0+ | 1 h | 30 d | added ([v2.35.0](https://github.com/advplyr/audiobookshelf/releases/tag/v2.35.0)) |
| v2.36.0+ | 1 h | 30 d | **10 min**, set by `REFRESH_TOKEN_GRACE_PERIOD` |

Sources: the v2.26.0 defaults are in [TokenManager.js@v2.26.0](https://github.com/advplyr/audiobookshelf/blob/v2.26.0/server/auth/TokenManager.js#L15-L17). The current defaults and env overrides (`ACCESS_TOKEN_EXPIRY`, `REFRESH_TOKEN_EXPIRY`, `REFRESH_TOKEN_GRACE_PERIOD`) are in [S/server/auth/TokenManager.js#L15-L31](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/auth/TokenManager.js#L15-L31). The v2.31.0 change is in its [release notes](https://github.com/advplyr/audiobookshelf/releases/tag/v2.31.0).

**Refresh-token rotation.** Every successful refresh rotates the refresh token. The old one is accepted only during the grace period, and a refresh in that window returns the token that is already current ([S/server/auth/TokenManager.js#L350-L420](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/auth/TokenManager.js#L350-L420)). On servers older than v2.35 there is no grace period, so two refreshes racing each other (for example, the app and a background task) can log the user out. Logos should serialise refreshes through one actor and store the new refresh token atomically before using the new access token. v2.35.1 also fixed a related bug: *"Duplicate refresh tokens across sessions can cause unexpected logout"* ([v2.35.1](https://github.com/advplyr/audiobookshelf/releases/tag/v2.35.1)).

**Expired tokens.** An expired access token gets a 401 from the JWT check ([S/server/auth/TokenManager.js#L277-L340](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/auth/TokenManager.js#L277-L340)). When the refresh token's session has expired, refresh returns 401 with an `error` message such as `"Refresh token expired"`. Treat that as "sign in again". From v2.36.0, refresh tokens are rejected as bearer tokens on normal API calls (`isBearerAccessTokenPayload`, [S/server/auth/TokenManager.js#L76-L86](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/auth/TokenManager.js#L76-L86); [v2.36.0](https://github.com/advplyr/audiobookshelf/releases/tag/v2.36.0): *"API and websocket authentication allowing refresh tokens"*).

**Rate limiting.** `/login`, `/auth/refresh` and the OIDC routes share one limiter: 40 requests per 10 minutes by default, configurable with `RATE_LIMIT_AUTH_MAX` and `RATE_LIMIT_AUTH_WINDOW` ([S/server/utils/rateLimiterFactory.js#L9-L10](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/rateLimiterFactory.js#L9-L10)). Logos must not refresh in a retry loop.

**Changing the password** invalidates all auth sessions (v2.36.0+).

### Legacy tokens (before v2.26.0, and still accepted)

Older Servers return one non-expiring JWT as `user.token` from `/login`. In v2.37.1 that token is still generated and returned (`@deprecated` in [S/server/auth/TokenManager.js#L102-L124](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/auth/TokenManager.js#L102-L124)), and `jwtAuthCheck` still accepts tokens that have no `exp` claim. It only flags them with `user.isOldToken` ([S/server/auth/TokenManager.js#L326-L333](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/auth/TokenManager.js#L326-L333)). Discussion #4460 said the old system would be removed *"no earlier than September 30, 2025"* ([v2.26.0](https://github.com/advplyr/audiobookshelf/releases/tag/v2.26.0)). As of v2.37.1 it has not been removed. Logos should use the access/refresh flow and treat `user.token` only as a fallback for Servers older than v2.26.0.

**API keys** (v2.26.0+) are created by an admin, act on behalf of one user and can expire. They work as bearer tokens, and for websockets from v2.37.0 ([v2.37.0](https://github.com/advplyr/audiobookshelf/releases/tag/v2.37.0)). They are an alternative to username and password but are not needed for v1.

**OIDC** exists (`GET /auth/openid` with PKCE, and a mobile redirect flow at `/auth/openid/mobile-redirect`; [S/server/Auth.js#L362-L460](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Auth.js#L362-L460)). This research did not map it in detail.

## 3. Listing a Library's Books

`GET /api/libraries/:id/items` ([S/server/controllers/LibraryController.js#L604-L639](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryController.js#L604-L639))

- **Pagination:** `limit` and `page` (zero-based), with `offset = page * limit`. **`limit=0` or no limit returns every Book in one response** ([S/server/utils/queries/libraryItemsBookFilters.js#L360-L380](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/queries/libraryItemsBookFilters.js#L360-L380)). The response is `{ results, total, limit, page, sortBy, sortDesc, filterBy, mediaType, minified, collapseseries, include }`.
- **Sort (`sort=` and `desc=1`):** `media.metadata.title` (respects the Server's ignore-prefix setting), `media.metadata.authorName`, `media.metadata.authorNameLF`, `media.metadata.publishedYear`, `media.duration`, `addedAt`, `size`, `birthtimeMs`, `mtimeMs`, `progress` (progress `updatedAt`), `progress.createdAt`, `progress.finishedAt`, `random`, and `sequence` (only with a series filter) ([S/server/utils/queries/libraryItemsBookFilters.js#L254-L300](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/queries/libraryItemsBookFilters.js#L254-L300)). **There is no sort by item `updatedAt`.**
- **Filter (`filter=<group>.<base64(value)>`).** The value is base64 and then URI-encoded ([S/server/utils/queries/libraryFilters.js#L13-L19](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/queries/libraryFilters.js#L13-L19)). Groups include `authors`, `series` (or `no-series`), `genres`, `tags`, `narrators`, `publishers`, `languages`, `progress` (`finished`, `not-started`, `not-finished`, `in-progress`), `tracks`, `ebooks`, `missing`, `issues`, `abridged`, `explicit`, `publishedDecades` and `recent` ([S/server/utils/queries/libraryItemsBookFilters.js#L100-L240](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/queries/libraryItemsBookFilters.js#L100-L240), [#L399-L540](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/queries/libraryItemsBookFilters.js#L399-L540)). **There is no filter for "updated since".**
- **The payload is always minified.** `minified=1` is only echoed back. The handler always serialises with `toOldJSONMinified()` ([S/server/models/LibraryItem.js#L293-L327](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/LibraryItem.js#L293-L327)). Each minified Book contains:
  - item level: `id, ino, libraryId, folderId, path, relPath, isFile, mtimeMs, ctimeMs, birthtimeMs, addedAt, updatedAt, isMissing, isInvalid, mediaType, numFiles, size` ([S/server/models/LibraryItem.js#L1000-L1026](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/LibraryItem.js#L1000-L1026))
  - `media`: `id, coverPath, tags, numTracks, numAudioFiles, numChapters, duration, size, ebookFormat` and `metadata { title, titleIgnorePrefix, subtitle, authorName, authorNameLF, narratorName, seriesName, genres, publishedYear, publishedDate, publisher, description, isbn, asin, language, explicit, abridged }` ([S/server/models/Book.js#L572-L592](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/Book.js#L572-L592), [#L640-L660](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/Book.js#L640-L660))
  - **Gotcha:** minified metadata has only display strings. `authorName` is comma-joined, and `seriesName` looks like `"Name #3, Other #1"`. There are **no author or series ids and no structured sequence**. The full `description` (HTML) *is* included, which makes up most of the payload size.
- **`include=`** accepts `rssfeed`, `share` (admin only) and `numEpisodesIncomplete` (podcasts). None of these matter to Logos.
- **Caching on the Server.** Every `GET /api/libraries*` response goes through an in-memory LRU cache (30 min TTL). Any write to a non-progress model clears the whole cache, and progress or session writes clear only `/me` and the personalised slices ([S/server/managers/ApiCacheManager.js#L5-L66](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/managers/ApiCacheManager.js#L5-L66); [S/server/routers/ApiRouter.js#L68](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/routers/ApiRouter.js#L68)). A repeated full-catalogue fetch with no changes is therefore cheap on the Server side. No `ETag` or `304` handling was found for these JSON routes.

### Caching a ~1000-Book catalogue cheaply

There is no delta or "updated since" endpoint. Options supported by the source:

1. **One full minified list** (`limit=0`, sorted by `addedAt`) on sign-in and on foreground or refresh. Then diff locally by `id` plus `updatedAt`. Item `updatedAt` is bumped by metadata edits, cover and chapter changes, and scans ([S/server/controllers/LibraryItemController.js#L270](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryItemController.js#L270), [S/server/scanner/Scanner.js#L124](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/Scanner.js#L124)). Removed Books are detected by an id missing from the list. Missing files show up as `isMissing: true`.
2. **Fetch details only for changed Books** with `POST /api/items/batch/get` and body `{ libraryItemIds: [...] }`, which returns **expanded** items in one round trip ([S/server/controllers/LibraryItemController.js#L740-L755](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryItemController.js#L740-L755)).
3. **Live invalidation (optional)** over the socket.io connection: emit `auth` with the token, then listen for `item_added`, `item_updated`, `items_updated`, `items_added`, `item_removed`, `series_added`, `series_updated`, `series_removed` and `user_item_progress_updated` ([S/server/SocketAuthority.js#L188](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/SocketAuthority.js#L188), [#L269-L361](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/SocketAuthority.js#L269-L361)). This is only a hint. A full list still has to run after reconnecting.

This research did not measure the size of a 1000-Book minified list. The `description` field dominates it, and HTTP compression would apply if the Server or its proxy compresses responses.

## 4. Series

- `GET /api/libraries/:id/series` takes `limit`, `page`, `sort` (`name`, `numBooks`, `addedAt`, `totalDuration`, `lastBookAdded`, `lastBookUpdated`, `random`), `desc` and `filter` (`authors`, `genres`, `tags`, `narrators`, `publishers`, `languages`, `progress`). Each series object includes **`books`: minified Books ordered by sequence** ([S/server/controllers/LibraryController.js#L742-L766](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryController.js#L742-L766), [S/server/utils/queries/seriesFilters.js#L129-L220](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/queries/seriesFilters.js#L129-L220)). The `minified` parameter is echoed back but ignored.
- `GET /api/libraries/:id/series/:seriesId?include=progress` returns one series plus `progress { libraryItemIds, libraryItemIdsFinished, isFinished }`. This is the supported route. `GET /api/series/:id` is marked `@deprecated` ([S/server/controllers/SeriesController.js#L25-L35](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/SeriesController.js#L25-L35)). v2.37.0 added a check that the series belongs to the library.
- Structured `{id, name, sequence}` for a Book's series is available only in **expanded** metadata (`media.metadata.series[]`), together with `authors[] {id, name}` ([S/server/models/Book.js#L550-L570](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/Book.js#L550-L570)). To get a series index without one expanded fetch per Book, Logos can either list series with their `books` arrays (this gives order and membership) or parse `seriesName`.

## 5. Book detail: chapters, audio files, tracks

`GET /api/items/:id?expanded=1&include=progress` ([S/server/controllers/LibraryItemController.js#L70-L101](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryItemController.js#L70-L101)). **Without `expanded=1` the shape is different** (legacy `toOldJSON`).

The expanded `media` adds the following to the minified fields ([S/server/models/Book.js#L668-L688](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/Book.js#L668-L688)):

- `chapters[]`: `{ id, start, end, title }`, in seconds on the whole-Book timeline.
- `audioFiles[]`: `{ index, ino, metadata { filename, ext, path, relPath, size, mtimeMs, ... }, duration, bitRate, codec, mimeType, format, channels, chapters, metaTags, exclude?, trackNumFromMeta, discNumFromMeta, ... }` ([S/server/models/Book.js#L45-L72](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/Book.js#L45-L72)).
- `tracks[]`: the playable audio files (those **not** marked `exclude`), in order. Each track is an audio file plus `title`, `startOffset` (seconds into the Book) and `contentUrl: "/api/items/<itemId>/file/<ino>"` ([S/server/models/Book.js#L260-L262](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/Book.js#L260-L262), [#L293-L303](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/Book.js#L293-L303)).
- `duration` is the sum of the included tracks. `libraryFiles[]` lists every file in the folder.
- `userMediaProgress` is present with `include=progress`.
- v2.36.0: *"Add all minified fields to expanded library item JSON"*. On older Servers, expanded is not a strict superset of minified, so the decoders must tolerate missing fields.

**Covers:** `GET /api/items/:id/cover?width=&format=webp|jpeg|png&raw=1&ts=<updatedAt>`. **No auth is needed**: covers and author images are on the auth ignore list ([S/server/Auth.js#L21](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/Auth.js#L21)). With `ts`, the response gets `Cache-Control: private, max-age=86400` ([S/server/controllers/LibraryItemController.js#L400-L432](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryItemController.js#L400-L432)). The width is clamped to 4096 (v2.33.2), and the format is restricted to webp, jpeg or png (v2.36.1).

## 6. Downloading original audio files

| Endpoint | Behaviour |
|---|---|
| `GET /api/items/:id/file/:ino` (`contentUrl`) | `res.sendFile` with the correct audio `Content-Type`. **It does not check the user's `download` permission**, only library access ([S/server/controllers/LibraryItemController.js#L989-L1004](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryItemController.js#L989-L1004)). |
| `GET /api/items/:id/file/:ino/download` | `res.download` (adds `Content-Disposition: attachment`). Returns 403 unless the user has `permissions.download` (on by default for new users) ([S/server/controllers/LibraryItemController.js#L1073-L1110](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryItemController.js#L1073-L1110); [S/server/models/User.js#L171](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/User.js#L171), [#L566-L568](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/User.js#L566-L568)). |
| `GET /api/items/:id/download` | A zip of the whole item folder. Not useful for Logos, because it includes non-audio files and cannot be resumed meaningfully. |

- **Range and resume.** Express 4 `res.sendFile` and `res.download` default to `acceptRanges: true` and `lastModified: true` ([Express 4 response API](https://expressjs.com/en/4x/api/response/)). So `Range: bytes=N-` works for resuming, and `Last-Modified` can serve as the `If-Range` validator. That makes the files suitable for background `URLSession` downloads with resume data.
- **Auth for downloads.** Send `Authorization: Bearer`, or use `?token=` for transfers where headers are awkward. A background download can outlive a 1 h access token. The Server checks the token once per request, so an in-flight transfer continues, but a resume after expiry needs a fresh token.
- **X-Accel.** If the Server sets `X-Accel` (an nginx deployment), both file routes return `204` with `X-Accel-Redirect`, and nginx serves the bytes. A correctly configured proxy turns this into the file response.
- **What to download.** Download the `tracks[]` (the included audio files), keyed by `ino`. `ino` is the file's inode as a string. It can change if files are moved or copied, so re-check it against the expanded item before downloading.

## 7. Progress and playback-session sync

### Media progress (one record per user per Book)

- **Read all:** `GET /api/me/progress` → `{ mediaProgress: [...] }` (**v2.36.0+**). On older Servers, read `GET /api/me` → `user.mediaProgress[]` ([S/server/controllers/MeController.js#L27-L29](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/MeController.js#L27-L29), [#L112-L115](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/MeController.js#L112-L115)). The same array also arrives in the login and `/authorize` payloads. Record shape: `{ id, libraryItemId, mediaItemId, duration, progress (0..1), currentTime, isFinished, hideFromContinueListening, lastUpdate (ms), startedAt, finishedAt }` ([S/server/models/MediaProgress.js#L155-L176](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/MediaProgress.js#L155-L176)).
- **Read one:** `GET /api/me/progress/:libraryItemId`.
- **Write:** `PATCH /api/me/progress/:libraryItemId` with body `{ currentTime, duration, progress, isFinished, finishedAt?, hideFromContinueListening? }`. `PATCH /api/me/progress/batch/update` takes an array of `{ libraryItemId, ... }` ([S/server/controllers/MeController.js#L275-L319](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/MeController.js#L275-L319)).
  - **Gotcha: PATCH has no conflict check.** It always overwrites (`applyProgressUpdate`), and `updatedAt` becomes the Server's time ([S/server/models/MediaProgress.js#L190-L250](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/MediaProgress.js#L190-L250)). A client-sent `lastUpdate` is ignored, because it is not a column.
  - The Server marks a Book finished automatically when fewer than 10 s remain (or by the library's percent or time-remaining setting, which the PATCH path does *not* pass in). Moving `currentTime` back un-finishes it. `isFinished: false` on a finished Book resets `currentTime` to 0.
  - The batch endpoint returns 200 even when individual items fail, so Logos cannot tell which writes failed.

### Playback sessions (listening history and stats)

- **Server-streamed sessions** (`POST /api/items/:id/play`, then `POST /api/session/:id/sync` and `/close`) are for streaming. They live in Server memory, `sync` sends a *delta* (`timeListened`), and a new `/play` from the same device closes the previous session ([S/server/managers/PlaybackSessionManager.js#L312-L470](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/managers/PlaybackSessionManager.js#L312-L470)). **Logos does not need these.**
- **Local sessions** (what the official apps use for downloaded playback):
  - `POST /api/session/local` with one session JSON → `200` or `500 <error>`.
  - `POST /api/session/local-all` with `{ deviceInfo, sessions: [...] }` → `{ results: [{ id, success, progressSynced, error? }] }` ([S/server/managers/PlaybackSessionManager.js#L103-L125](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/managers/PlaybackSessionManager.js#L103-L125), [#L281-L291](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/managers/PlaybackSessionManager.js#L281-L291)).
  - Session fields used: `id` (client-generated; use a UUIDv4, because `play_local_*` ids are remapped in memory only), `libraryItemId`, `bookId?`, `mediaType: "book"`, `playMethod: 3` (LOCAL, [S/server/utils/constants.js#L29-L34](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/constants.js#L29-L34)), `duration`, `startTime`, **`currentTime`**, **`timeListening`** (total seconds, absolute), `startedAt`, **`updatedAt` (ms)**, `displayTitle?`, `displayAuthor?`, `mediaMetadata?`, `deviceInfo { deviceId, clientName, clientVersion, manufacturer, model }` ([S/server/objects/PlaybackSession.js#L118-L175](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/objects/PlaybackSession.js#L118-L175)). The Server fills in missing metadata.
  - **Re-posting the same session id updates it** with absolute `currentTime`, `timeListening` and `updatedAt` ([S/server/managers/PlaybackSessionManager.js#L206-L219](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/managers/PlaybackSessionManager.js#L206-L219)). **Retries are therefore idempotent**, which suits an offline outbox.
  - **Built-in last-write-wins.** The Server updates the Book's progress from the session only if `progress.updatedAt <= session.updatedAt`. Otherwise `progressSynced: false` ([S/server/managers/PlaybackSessionManager.js#L230-L262](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/managers/PlaybackSessionManager.js#L230-L262)). This path *does* apply the library's mark-as-finished settings, and it emits `user_item_progress_updated` to the user's other devices.
  - Caveat: the comparison uses the client's `updatedAt` against the progress row's `updatedAt`, which is Server time. Device clock skew therefore affects who wins.
- **History:** `GET /api/me/listening-sessions?itemsPerPage=&page=` and `GET /api/me/item/listening-sessions/:libraryItemId`. v2.33.0 fixed IDOR bugs in these and in the progress and bookmark endpoints.
- **Bookmarks** (`/api/me/item/:id/bookmark`, plus `GET /api/me/bookmarks` in v2.36.0+) exist but are out of scope for v1.

## 8. Server-version summary

| Version | Change that affects Logos |
|---|---|
| < 2.26.0 | Only the legacy non-expiring `user.token`. No `/auth/refresh`. |
| 2.26.0 | Access and refresh JWTs, `x-return-tokens` and `x-refresh-token`, API keys, auth rate limiter. Defaults: access 12 h, refresh 7 d. |
| 2.31.0 | Defaults change to access **1 h** and refresh **30 d**. |
| 2.33.0 | IDOR fixes on sessions, progress and bookmarks. Progress and session writes no longer clear the whole API cache. |
| 2.35.0 / 2.35.1 | Refresh grace period added. Duplicate-refresh-token logout bug fixed. |
| 2.36.0 | Grace period 10 min. Refresh tokens rejected as bearer tokens. `GET /api/me/progress`. Expanded JSON is a superset of minified. `/logout?allDevices=1`. Password change logs out all sessions. |
| 2.37.0 | API keys work for websockets. The series-for-library endpoint checks library membership. Node 24. |
| 2.37.1 | Latest at the time of writing. The legacy token is still accepted. |

## 9. Open points this research did not settle

- The actual byte size of a 1000-Book minified list, and whether typical Server deployments gzip API responses.
- Whether `ino` stays the same across Server rescans on common filesystems such as Docker bind mounts and NAS shares. It is the file key for downloads and `contentUrl`.
- The minimum Server version Logos will support. The auth design depends on it, because Servers before 2.26 have no refresh tokens and Servers before 2.35 have no grace period.
