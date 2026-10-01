# Stability of audiobookshelf file ids across rescans

Research for [#14](https://github.com/kracobsen/logos/issues/14). Question: does an audio file's `ino`, and the Book's id, stay the same across Server rescans, restarts and container recreation on Docker bind mounts and NAS shares? If not, what should Logos key Downloads on, and how does the Server handle `ino` changes?

**Sources.** The Server source at tag [`v2.37.1`](https://github.com/advplyr/audiobookshelf/tree/v2.37.1) (commit `3563d49`, the latest release when this was written), the Server's issue tracker (maintainer and reporter evidence), the Linux kernel docs for CIFS and overlayfs, the mergerfs docs, and the source of the `send` and `etag` packages that Express uses to serve files. This builds on the [API research for #2](https://github.com/kracobsen/logos/blob/research/abs-api/docs/research/audiobookshelf-api.md), §6.

`S/` means `https://github.com/advplyr/audiobookshelf/blob/v2.37.1/`. The Server calls a Book a "library item".

## Answer in short

- **`ino` is not a stable identifier.** It is the raw `stat().ino` of the file at scan time ([S/server/utils/fileUtils.js#L50-L64](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/fileUtils.js#L50-L64)). It is stable only if the filesystem the Server sees keeps inode numbers stable. On local disks used directly or through a Docker bind mount (ext4, XFS, btrfs, ZFS), it stays the same across rescans, restarts and container recreation. It changes when a file is replaced rather than edited in place, when it is copied, or when it moves to a different filesystem. On CIFS without server inode numbers, on some NFS setups (one Synology report), on mergerfs, and on Windows drive pools it can change for every file after a remount or reboot. When that happens, the Server updates the stored `ino`, so the `contentUrl` changes.
- **The Book (library item) id is much more stable.** It is a random UUID assigned once, when the Server first creates the item. Rescans keep it, because the Server matches existing items **by path first** and uses `ino` only as a fallback. It changes when the Server treats the Book as a new item: the folder is renamed or moved and the inode fallback fails, the folder is copied, the library folder is removed and added again, or the item is deleted and rescanned. Two inode bugs can also attach the id to a different Book's folder.
- **What Logos should do.** Key a Download on the **library item id**, and each downloaded file on its **`relPath`** inside the item. Treat `ino` as a short-lived URL token: re-read it from a fresh expanded item before every download or resume. Decide that a file has changed by comparing **`metadata.size` and `metadata.mtimeMs`**, and use the HTTP `ETag`/`Last-Modified` validators to make resumes safe.

## 1. How the Server gets and stores `ino`

- Each file's `ino` is `String(stat.ino)` from `fs.stat(path, { bigint: true })`, taken during the scan together with `size`, `mtimeMs`, `ctimeMs` and `birthtimeMs` ([S/server/utils/fileUtils.js#L50-L64](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/fileUtils.js#L50-L64), [#L107-L115](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/fileUtils.js#L107-L115); [S/server/objects/files/LibraryFile.js#L63-L75](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/objects/files/LibraryFile.js#L63-L75)). The Server does not read `st_dev`, so the value is not unique across filesystems.
- The library item has an `ino` of its own: the inode of the Book's **folder**, or of the file for a single-file item in the library root ([S/server/scanner/LibraryScanner.js#L342-L355](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryScanner.js#L342-L355)). A folder with no inode value is skipped.
- Each audio file's `ino` is stored **twice**: in `libraryItems.libraryFiles[]` and in `books.audioFiles[]` ([S/server/objects/files/AudioFile.js#L113-L114](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/objects/files/AudioFile.js#L113-L114)).
- `contentUrl` is `/api/items/<itemId>/file/<audioFile.ino>` ([S/server/models/Book.js#L299](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/Book.js#L299)). The file route looks the `ino` up in **`libraryFiles`**, not `audioFiles`, and returns `404` if it is not there ([S/server/controllers/LibraryItemController.js#L1230-L1235](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/controllers/LibraryItemController.js#L1230-L1235); [S/server/models/LibraryItem.js#L951-L955](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/models/LibraryItem.js#L951-L955)). A stale `ino` therefore gives a plain 404.

## 2. How a scan matches what it finds to what it already has

**Library items (full or partial library scan).** For each existing item, the scanner looks for a scanned folder with the **same path**. If there is none, it falls back to matching the folder `ino`, or a single-file item's `ino` against library files ([S/server/scanner/LibraryScanner.js#L170-L180](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryScanner.js#L169-L180), [#L641-L647](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryScanner.js#L641-L647)). If neither matches, the item is marked `isMissing` but **not deleted** ([#L182-L199](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryScanner.js#L182-L200)). Every folder left unmatched becomes a new item with a new id. The maintainer confirmed that path-first matching has applied since v2.4.3: *"As of 2.4.3 the scanner is no longer checking for inode first. It is looking for exact matching file path first then falling back to inode"* ([#1447 comment](https://github.com/advplyr/audiobookshelf/issues/1447)).

**File watcher.** The watcher also tries the path first, then three inode lookups: folder `ino` against item `ino`, single-file `ino` against library files, and file `ino`s against item `ino` ([S/server/scanner/LibraryScanner.js#L564-L583](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryScanner.js#L563-L583), [#L657-L708](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryScanner.js#L657-L708)). If an inode lookup matches, the item keeps its id and its path is rewritten.

**Files within an item.** Each stored library file is matched to a scanned file by **path first**, then by `ino` ([S/server/scanner/LibraryItemScanData.js#L225-L233](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryItemScanData.js#L225-L233)). When they match, `compareUpdateLibraryFile` copies over the new `ino` and any changed `size`, `mtimeMs`, `ctimeMs` and `birthtimeMs`, and marks the file modified ([#L293-L316](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryItemScanData.js#L291-L316)). The item-level `ino`, path and timestamps are compared the same way ([#L183-L215](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryItemScanData.js#L183-L220)).

**Audio files on the Book.** A modified audio file is probed again with ffprobe, matched by path and then by `ino`, and merged in with `AudioFile.updateFromScan`. That function copies every key except `manuallyVerified`, `ctimeMs`, `addedAt` and `updatedAt`, so **the new `ino` reaches `audioFiles[]`** and `contentUrl` ([S/server/scanner/BookScanner.js#L85-L115](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/BookScanner.js#L84-L112); [S/server/objects/files/AudioFile.js#L166-L197](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/objects/files/AudioFile.js#L166-L196)). The item is saved, which bumps its `updatedAt`, and an `items_updated` socket event is sent ([S/server/scanner/LibraryScanner.js#L201-L228](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/LibraryScanner.js#L204-L226)).

**What this means:**

- If only the inode changes and the path stays the same, the Book keeps its id and its progress, and the file's `ino` (and so `contentUrl`) is replaced. The full re-probe makes such scans slow ([#2509](https://github.com/advplyr/audiobookshelf/issues/2509), [#2794](https://github.com/advplyr/audiobookshelf/issues/2794)).
- If the path changes and the inode stays the same (a rename or move within one filesystem), the inode fallback usually keeps the Book's id. One gap: for folder-based Books, the file-inode fallback runs only for single-file root items, so a folder that is recreated and has its files moved into it gets a new id, and progress is left on the old, missing item ([#5379](https://github.com/advplyr/audiobookshelf/issues/5379), open; fix PR [#5380](https://github.com/advplyr/audiobookshelf/pull/5380), open).
- If both the path and the inode change (copy and delete, a move across filesystems, removing and re-adding the library folder), the Server creates a **new Book with a new id**, and the old one stays as `isMissing` ([#4776](https://github.com/advplyr/audiobookshelf/issues/4776)).

## 3. When `ino` actually changes, by storage setup

| Setup | Is `ino` stable across rescans, restarts and container recreation? | Evidence |
|---|---|---|
| Local ext4, XFS, btrfs or ZFS, bind-mounted into Docker | **Yes.** A bind mount shows the host filesystem's own inodes, and recreating the container does not touch them. The maintainer's XFS inodes look like `649362779914890946`, and he reports persistent inodes on Unraid. | [#1447](https://github.com/advplyr/audiobookshelf/issues/1447), [#2509](https://github.com/advplyr/audiobookshelf/issues/2509) (advplyr: *"I use Unraid along with many users and have persistent inode values"*) |
| Media inside the container's own overlay filesystem (not a volume) | Not guaranteed. The overlayfs docs say `st_ino` *"will only be unique when combined with st_dev, and both of these can change over the lifetime of a non-directory object"* unless all layers are on one filesystem or `xino` is on. Recreating the container also discards the files. | [kernel overlayfs.rst](https://github.com/torvalds/linux/blob/master/Documentation/filesystems/overlayfs.rst) |
| CIFS/SMB with `serverino` (the kernel default when the server supports it) | Usually yes. The kernel docs say inode numbers *"may be persistent"*, but they are not guaranteed unique when several server-side filesystems are exported under one share. | [kernel cifs/usage.rst](https://github.com/torvalds/linux/blob/master/Documentation/admin-guide/cifs/usage.rst) |
| CIFS/SMB with `noserverino`, or a server that gives no unique ids | **No.** *"These inode numbers will vary after unmount or reboot."* A reporter on Unraid (CIFS through the Unassigned Devices plugin) saw every inode change after a remount and container restart. | kernel cifs/usage.rst; [#2509](https://github.com/advplyr/audiobookshelf/issues/2509) |
| SMB from Windows on StableBit DrivePool, or a Windows drive bind-mounted into Docker | **No.** Ids change when the pool rebalances a file onto another disk, or when the layer that numbers files changes. | [#2509 (2026-07 comment)](https://github.com/advplyr/audiobookshelf/issues/2509), [#5568](https://github.com/advplyr/audiobookshelf/issues/5568) |
| NFS from a Synology NAS (Proxmox LXC client) | Changed for every item in one report. The cause was not found. The maintainer called it "transient inode values". | [#2794](https://github.com/advplyr/audiobookshelf/issues/2794) |
| mergerfs | It depends on `inodecalc`. mergerfs calculates its own inodes. Changing the setting renumbers everything, and `devino-hash` does not prevent changes when files move between branches. The docs warn that software which relies on inodes *"often break[s] if a value changes unexpectedly"*. | [mergerfs inodecalc](https://github.com/trapexit/mergerfs/blob/master/mkdocs/docs/config/inodecalc.md) |
| Any filesystem: a file replaced by write-to-temp-then-rename, or by a copy | **New inode at the same path.** For example, an ffmpeg trim moved over the original. The Server picks up the new `ino` through path matching, but bugs have produced duplicate audio file entries this way. | [#4415](https://github.com/advplyr/audiobookshelf/issues/4415) (open) |
| The Server's own "embed metadata" tool | **Same inode, new bytes.** It writes to a temporary file and then copies that back into the existing file with a write stream (`flags: 'w'`), so the path and inode stay the same while the size and mtime change. | [S/server/utils/ffmpegHelpers.js#L302-L375](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/ffmpegHelpers.js#L302-L375), [S/server/utils/fileUtils.js#L545-L577](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/fileUtils.js#L545-L577) |

The last row matters most: **an unchanged `ino` does not mean unchanged content.** The maintainer's position is that *"Abs relies on your file system having static inode values"* ([#2509](https://github.com/advplyr/audiobookshelf/issues/2509)). That is an assumption, not a guarantee.

## 4. Known Server bugs around `ino` (open as of v2.37.1)

- **[#5568](https://github.com/advplyr/audiobookshelf/issues/5568): stale `audioFiles[].ino` makes downloads 404 permanently.** `libraryFiles[].ino` and `audioFiles[].ino` can drift apart (seen after a filesystem renumbering; one possible cause is a scan that dies between the two saves). After that, `contentUrl` and `/file/:ino/download` return 404 while streaming still works, and no scan repairs it: the scan returns `UPTODATE` because `hasMediaChanges` is false. Fix PR [#5569](https://github.com/advplyr/audiobookshelf/pull/5569) is open. **Impact on Logos:** a 404 on a file that the expanded item still lists may be this bug and not a deleted file. Logos cannot fix it from the client. It should show "file unavailable on Server" and keep any existing local copy.
- **[#1447](https://github.com/advplyr/audiobookshelf/issues/1447): Books "overwritten" by a mistaken inode identity.** Inode numbers are unique only per filesystem. On two ZFS datasets, a new folder and an old Book's folder both had inode `8717`, and the watcher attached the new folder to the old Book's id. The reported causes are inode reuse after a deletion and collisions across mounts. The issue is still reported on 2.32.1 (2026-01). Fix PR [#4621](https://github.com/advplyr/audiobookshelf/pull/4621) is open. **Impact on Logos:** the Book id can stay the same while its files become a different book. Logos must compare file identity as well as the id.
- **[#5379](https://github.com/advplyr/audiobookshelf/issues/5379)**: covered in §2. A renamed or recreated folder gets a new id.
- **[#5010](https://github.com/advplyr/audiobookshelf/issues/5010)**: a new book takes on an existing book's metadata (same symptom family as #1447).

## 5. Is the Book (library item) id stable?

- New items get `uuidv4()` when they are created ([S/server/scanner/BookScanner.js#L532](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/scanner/BookScanner.js#L532)). No code path regenerates the id of an existing item. Rescans, forced rescans, Server restarts and container recreation all keep it, because it lives in the SQLite database, not in the filesystem.
- **It changes** in these cases:
  1. The Server cannot match the folder. Both the path and the inode changed, or §2's gap applies.
  2. A user removes the item, or removes and re-adds the library folder ([#4776](https://github.com/advplyr/audiobookshelf/issues/4776)).
  3. Historically, the move to SQLite in [v2.3.0](https://github.com/advplyr/audiobookshelf/releases/tag/v2.3.0) gave every item a new UUID in place of the old `li_…` ids ([S/server/utils/migrations/dbMigration.js#L270](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/migrations/dbMigration.js#L270), [#L295](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/migrations/dbMigration.js#L295)).
- **It can wrongly move to different content** through the #1447 inode collision.
- Media progress is keyed on the library item id (see the #2 research, §7), so the Server's own model already assumes this id is the stable handle.

## 6. Recommendation for Logos

**Keys**

- **Download record:** the library item id. Store the Server's `updatedAt` and the ordered track list from when the download was made.
- **Each downloaded file:** `(libraryItemId, audioFile.metadata.relPath)`. `relPath` is relative to the Book's folder ([S/server/utils/scandir.js#L130-L139](https://github.com/advplyr/audiobookshelf/blob/v2.37.1/server/utils/scandir.js#L130-L139)). This is the same identity the Server tries first. Also store `ino`, `metadata.size`, `metadata.mtimeMs` and `duration`, plus the `ETag` and `Last-Modified` from the response. Do **not** use `ino` as the key or as the local file name.

**Before each download, resume or retry**

- Fetch `GET /api/items/:id?expanded=1` and build the URL from that response's `ino` (or `contentUrl`). Do not reuse an `ino` from an old catalogue snapshot.
- If a file 404s while the fresh item still lists it, refetch the item once and retry. If it still 404s, report it as a Server-side problem (#5568) and keep the local copy.

**Detecting that a file changed (staleness)**

- A file is stale if the fresh item has no audio file at its stored `relPath`, or if `size` or `mtimeMs` differs. A changed `ino` alone means only "refresh the URL token", not "download again".
- The Book needs reconciling if the set or order of included `tracks[]` (by `relPath`) differs. That covers added, removed and excluded files.
- Use item `updatedAt` from the cheap minified list (#2 research, §3) to decide which Books to fetch in expanded form. Any change the scanner detects, including an `ino` change, saves the item.
- On CIFS, `mtimeMs` has jumped between whole seconds and millisecond precision across mounts ([#2509](https://github.com/advplyr/audiobookshelf/issues/2509): `1699894581000` → `1699894581578`). A false "changed" costs one extra download, which is acceptable, but do not compare on `ctimeMs` or `birthtimeMs`.
- **Identity cross-check against #1447:** if a Book id's `title` or `duration` changes sharply while its download is complete, treat it as a different Book. Do not merge its progress.

**HTTP validators for resume**

- Express 4 serves the file with the `send` module (version 0.18.0 in the Server's lockfile). It sets `Last-Modified` from mtime and, by default, a **weak** `ETag` `W/"<size hex>-<mtime ms hex>"` built from `fs.Stats` ([send@0.18.0 index.js](https://github.com/pillarjs/send/blob/0.18.0/index.js#L113-L115), [#L873-L883](https://github.com/pillarjs/send/blob/0.18.0/index.js#L873-L883); [etag@1.8.1 index.js](https://github.com/jshttp/etag/blob/v1.8.1/index.js#L70-L90), [#L126-L131](https://github.com/jshttp/etag/blob/v1.8.1/index.js#L126-L131)). `send` honours `If-Range` with that ETag or with the date, and sends the whole file if the validator does not match ([send index.js#L446-L465](https://github.com/pillarjs/send/blob/0.18.0/index.js#L446-L465)). So the HTTP validator is the same size-plus-mtime check, done by the Server at request time. An `ino` change alone does not invalidate resume data.
- Behind nginx `X-Accel`, nginx sends its own `ETag` and `Last-Modified`, also built from mtime and size. Logos should not parse the ETag format, only compare it.

## 7. Open points this research did not settle

- How often #5568 (drift between `libraryFiles` and `audioFiles`) happens in practice. Its cause is not established.
- Whether the official mobile app keys its downloads on `ino`. Its source was not read.
- Whether open PRs #5569, #5380 and #4621 will be merged, and in which version. Logos should not depend on them.
