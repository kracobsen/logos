# Performance budgets

Every budgeted path below has a signpost (`BudgetedPath` in `LogosKit/Sources/Domain/Signposts.swift`, subsystem `Logos`, category `Budgets`). From [Grilling: v1 performance budgets](https://github.com/kracobsen/logos/issues/15).

## How budgets are measured

- On an iPhone 15 Pro, with a Release build and no debugger attached.
- As the median of 5 runs, plus a worst-run ceiling where the table gives one.
- On a copy of the real 940-Book Library, plus a generated 3000-Book copy (the Data column says which).
- With XCTest performance tests (`XCTApplicationLaunchMetric`, `XCTOSSignpostMetric` including scroll hitches) in the UI test target. Baselines are recorded on the iPhone during manual sessions, not in CI.

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
