# Performance budgets

Every budgeted path below has a signpost (`BudgetedPath` in `LogosKit/Sources/Domain/Signposts.swift`, subsystem `Logos`, category `Budgets`). From [Grilling: v1 performance budgets](https://github.com/kracobsen/logos/issues/15).

## How budgets are measured

- On an iPhone 15 Pro, with a Release build and no debugger attached.
- As the median of 5 runs, plus a worst-run ceiling where the table gives one.
- On a copy of the real 940-Book Library, plus a generated 3000-Book copy (the Data column says which).
- With XCTest performance tests (`XCTApplicationLaunchMetric`, `XCTOSSignpostMetric` including scroll hitches) in the UI test target. Baselines are recorded on the iPhone during manual sessions, not in CI.

## Running the performance tests

The tests are in `LogosUITests/*PerformanceTests.swift`. Each measures 5 runs.

1. Plug in the iPhone 15 Pro, unlocked, and make sure `Config/Local.xcconfig` has your team (see CLAUDE.md). Quit other apps; let the phone cool down and keep it on the charger or above 50 %.
2. Run the `LogosPerformance` scheme's tests. It builds the **Performance** configuration (Release optimisation, plus the `LOGOS_TEST_LAUNCH` test launches; never archive it) and runs without a debugger:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
       -project Logos.xcodeproj -scheme LogosPerformance \
       -destination 'platform=iOS,name=<your iPhone>' \
       -derivedDataPath .build/DerivedData -resultBundlePath ~/Desktop/perf-$(date +%Y%m%d-%H%M).xcresult
   ```

   Narrow with `-only-testing:LogosUITests/LibraryPerformanceTests` (or `.../LibraryPerformanceTests/testSortChange`). In Xcode: choose the `LogosPerformance` scheme and the iPhone, then Product › Test.
3. Print the median and worst run of each metric: `scripts/perf-results.sh <result>.xcresult`. Record them in the PR description next to the budget (median, and worst where the table has a ceiling). To keep a baseline in Xcode, open the result, select the test and choose Set Baseline (baselines are per device and stay out of git).

The data comes from test launches (`Logos/TestLaunch.swift`): `library940` and `library3000` are generated Libraries (`FixtureLibrary`, the same every time: titles over every index letter, about a third in Series, 90 % with covers, about 18 % started or Finished, and 3 short downloaded Books with real silent audio), signed in to an offline fake Server. The first launch of a run makes the data (which takes a while for 3000 Books); measured launches reuse it. The generated 940 stands in for the real 940-Book Library; to measure on the real one, sign in to your Server with a Release build and use Instruments (Logos › Budgets signposts).

| Test | Budget | Data |
|---|---|---|
| `LaunchPerformanceTests/testColdLaunch940`, `testColdLaunch3000` | Cold launch → interactive Library (launch metric, and the `ColdLaunchToInteractiveLibrary` signpost) | 940, 3000 |
| `LaunchPerformanceTests/testLastPlayedBookReady` | Last-played Book ready | 940 |
| `LaunchPerformanceTests/testSyncWithNoChanges940`, `testSyncWithNoChangesAndApplyProgress3000` | Sync with no changes (local part only, against the offline fake Server), Apply fetched progress | 940, 3000 |
| `LibraryPerformanceTests/testScrollLibrary`, `testScrollInProgress`, `testScrollSeriesTab`, `testScrollSeriesPage` | Scroll (hitch ratio), and Memory while browsing (peak physical memory) | 3000 |
| `LibraryPerformanceTests/testLetterIndexJump` | Letter-index jump | 3000 |
| `LibraryPerformanceTests/testSearchKeystroke` | Search keystroke → updated list | 3000 |
| `LibraryPerformanceTests/testSortChange` | Sort change (Title ↔ Author) | 3000 |
| `LibraryPerformanceTests/testTapBookToDetail` | Tap Book → detail | 3000 |
| `PlayerPerformanceTests/testPlayLoadedBook` | Play, Book already loaded → audio | 940 |
| `PlayerPerformanceTests/testPlayOtherBook` | Play, another downloaded Book → audio | 940 |
| `PlayerPerformanceTests/testSkipToAudio` | Seek / skip / Chapter jump → audio | 940 |
| `PlayerPerformanceTests/testPlayerSheetHitches` | Player sheet open and scrubbing (`XCTHitchMetric`) | 940 |

On the simulator the tests run, but the numbers don't count: XCUITest's automation slows launch several-fold, and hitch ratios (scroll and `XCTHitchMetric`) are only reported on a device (the simulator reports scroll durations only).

Not covered by a test, measured by hand: return from background (no signpost yet), first sync after sign-in (needs a real Server on Wi-Fi), the Wi-Fi part of a sync, scrolling while a sync or Download runs, Download throughput, memory while playing in the background, battery, and when sound actually starts (the play and seek signposts end when AVPlayer reports playing or the seek has landed). Tap Book → detail is measured on 3000 Books (the table says 940; 3000 is the harder case).

## Budgets

| Path | Median | Worst | Data |
|---|---|---|---|
| Cold launch → interactive Library (local rows visible, scrollable, tappable) | ≤ 400 ms | ≤ 700 ms | 940 and 3000 |
| Return from background → interactive | ≤ 100 ms | — | 940 |
| Last-played Book ready, after interactive | ≤ 300 ms | — | 940 |
| Scroll any list or the Series page (hitch ratio) | < 5 ms/s | — | 3000 |
| Letter-index jump | ≤ 100 ms | — | 3000 |
| Search keystroke → updated list | ≤ 50 ms | — | 3000 |
| Sort change | ≤ 100 ms | — | 3000 |
| Tap Book → detail | ≤ 100 ms | — | 940 |
| Play, Book already loaded → audio | ≤ 150 ms | ≤ 300 ms | — |
| Play, another downloaded Book → audio | ≤ 500 ms | ≤ 800 ms | — |
| Seek / skip / Chapter jump → UI | same frame | — | — |
| Seek / skip / Chapter jump → audio | ≤ 500 ms | ≤ 800 ms | — |
| Player sheet open and scrubbing (hitch ratio) | < 5 ms/s | — | — |
| Sync with no changes, start to finish, on Wi-Fi | ≤ 1 s (local part ≤ 150 ms, off the main thread) | — | 940 and 3000 |
| First sync after sign-in, on Wi-Fi | rows ≤ 3 s, all Book data ≤ 30 s, all covers ≤ 2 min | — | 940 |
| Apply fetched progress | ≤ 100 ms, off the main thread | — | 3000 |
| Scrolling and player while a sync or Download runs | < 5 ms/s | — | 3000 |
| Download throughput | ≥ 80% of the same phone fetching the file directly | — | — |
| Memory while browsing | ≤ 150 MB | — | 3000 |
| Memory while playing in the background, screen off | ≤ 100 MB | — | — |
| Battery for one hour of playback with the screen off | about the same as Apple Books (checked by hand) | — | — |

## Rules

- Nothing on the launch path touches the network or runs the file check.
- Signposts mark each budgeted path. Wrap the work in `Signposts.measure(_:)` / `Signposts.measureSync(_:)`, or call `Signposts.begin(_:)` and `end()` for a path that spans callbacks. A new budget gets a new `BudgetedPath` case.

## Enforcement

- A PR touching a budgeted path records the iPhone measurements next to the budget in its description.
- A breach blocks the merge unless the PR changes the budget in this file with a written reason.
- Persistence wins over performance when the two conflict.
