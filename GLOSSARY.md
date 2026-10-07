# Logos

A personal iPhone client for an audiobookshelf server that plays audiobooks from local downloads only.

## Language

**Server**:
The single audiobookshelf instance the app is signed in to, with one user account.
_Avoid_: Backend, host, instance

**Library**:
The one audiobookshelf book library the app is pointed at, chosen at sign-in.
_Avoid_: Collection, catalogue (when meaning the server-side library)

**Book**:
A single audiobook in the Library; the unit you browse, download, and play.
_Avoid_: Title, item, library item, audiobook

**Download**:
A whole Book (all of its audio files and its cover) kept on the device; it is downloaded only when every file is present and verified, and only a downloaded Book can be played.
_Avoid_: Offline copy, cached book, partial download

**In Progress**:
A Book that has been started and not finished, whether or not it is downloaded.
_Avoid_: Continue listening, currently reading, started

**Chapter**:
A named section of a Book, as the Server reports it; a Book the Server reports no Chapters for is a single Chapter. The unit the Sleep Timer counts.
_Avoid_: Track, file, part

**Sleep Timer**:
A request to stop playback at the end of the Xth Chapter from now, counting the Chapter currently playing as the first.
_Avoid_: Timer, sleep mode
