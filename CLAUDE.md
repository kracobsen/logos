## Agent skills

### Issue tracker

Issues are tracked in GitHub Issues for `kracobsen/logos` (via the `gh` CLI). See `docs/agents/issue-tracker.md`.

### Triage labels

Default vocabulary: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one `GLOSSARY.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.

## Project layout

- `Logos.xcodeproj` is a thin app target only: entitlements, Info, signing and `@main` (`Logos/`, a buildable folder). It is the composition root (plain initializer injection). Build settings live in `Config/*.xcconfig`, never in the project file. Team and bundle-ID prefix go in the git-ignored `Config/Local.xcconfig` (copy `Config/Local.xcconfig.template`).
- Everything else is in the local Swift package `LogosKit/`. All structural changes (targets, edges, dependencies) happen in `LogosKit/Package.swift`, never in the project file.
- iOS 27, iPhone only, Swift 6 language mode (complete strict concurrency), warnings as errors. UI, Playback and the app default to `@MainActor`.

## Module graph

Allowed edges (Domain is the base every module may use):

| Module | May depend on |
|---|---|
| Domain | nothing (Apple frameworks only) |
| ServerAPI | Domain |
| Store | Domain, GRDB |
| Sync | Domain, ServerAPI, Store |
| Downloads | Domain, ServerAPI, Store |
| Playback | Domain, Store |
| UI | Domain, Store, Sync, Downloads, Playback |

Forbidden edges: everything not in the table. In particular **Playback must never import ServerAPI** (it can't reach the network), nothing but Store imports GRDB, and no module depends on UI. Xcode builds all modules into one directory, so a forbidden `import` can still compile: `scripts/check-module-graph.sh` checks both the manifest and the imports, and CI runs it. Changing an edge means changing `Package.swift`, that script and this table together.

Shared seams in Domain: the `Clock` (inject it, never call `Date()` or `Task.sleep` in Sync, Downloads or Playback; `TestClock` in tests), `Diagnostics.logger(_:)` (each module has a `log` under its own `LogCategory`), and `Signposts` for budgeted paths.

## Dependencies

GRDB and Apple frameworks only. A new dependency needs an ADR in `docs/adr/`. `LogosKit/Package.resolved` is checked in, and builds resolve only from it.

## Checks and tests

Prefix Xcode tooling with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` points at CommandLineTools (the scripts do this for you).

- `scripts/format.sh`: swift-format lint (strict); `scripts/format.sh --fix` rewrites.
- `scripts/check-module-graph.sh`: the module graph and dependency policy.
- `scripts/test.sh`: builds the app and runs every LogosKit unit test on the simulator (`DEVICE`, default `iPhone 18 Pro`). Pass `-only-testing:DomainTests` etc. to narrow.

CI (`.github/workflows/ci.yml`) runs all three on every PR. Unit tests use Swift Testing, one test target per module (`<Module>Tests`).

### Integration tests

`scripts/integration-test.sh` runs the `IntegrationTests` target (ServerAPI and Sync against a real Server). It generates the fixture Library (`scripts/integration/make-fixture-library.sh`), starts audiobookshelf 2.37.1 (pinned by digest) in Docker on a free `127.0.0.1` port, seeds it (root `root`/`rootpass`, user `listener`/`listenerpass`, one book Library "Fixtures"), runs the tests, fails if any were skipped, and tears everything down. `--serve` starts and seeds the Server and prints its address for manual poking. Extra arguments go to xcodebuild, e.g. `-only-testing:IntegrationTests/HarnessTests`.

- Needs Docker; CI doesn't run it. A PR touching ServerAPI or Sync attaches its result.
- Tests get the Server from `IntegrationServer.current()`, which rejects any non-loopback URL. Never point integration tests at a real Server. The credentials above belong to the throwaway container only.
- The `IntegrationTests` target is outside the `Logos` scheme, so `scripts/test.sh` doesn't run it, and its Server tests skip when the harness isn't running.

## Manual checklists

A PR touching device-only behaviour (interruptions and routes; lock screen and Control Center; background Downloads and surviving a reboot; listening at 1×, 2× and 3×; battery; smoothness) must carry a manual checklist in its description that the human signs off before merge.

## Performance budgets

The budget table, how it's measured and how it's enforced live in `docs/performance-budgets.md`. A PR touching a budgeted path records iPhone measurements against it.
