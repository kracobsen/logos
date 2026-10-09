# Logos

A personal iPhone client for an [audiobookshelf](https://www.audiobookshelf.org) Server. Logos browses one book Library, downloads whole Books to the device and plays them from those Downloads only, syncing listening progress back to the Server.

iOS 27, iPhone only, Swift 6. Domain terms (Server, Library, Book, Download, Finished, …) are defined in [GLOSSARY.md](GLOSSARY.md).

## Requirements

- macOS with Xcode that ships the iOS 27 SDK.
- An Apple ID signed in to Xcode (a free account works for running on your own iPhone; a paid Apple Developer Program membership is needed for TestFlight).
- An audiobookshelf Server reachable over **HTTPS**. Normal builds refuse plain HTTP sign-in.
- Docker, only for the integration tests.

If `xcode-select -p` points at CommandLineTools, prefix Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the scripts do this for you), or run `sudo xcode-select -s /Applications/Xcode.app`.

## Running in the Simulator

No setup needed: open `Logos.xcodeproj`, pick the `Logos` scheme and an iPhone simulator, and press Run (⌘R).

## Running on an iPhone

1. **Configure signing.** Copy the template and fill it in:

   ```sh
   cp Config/Local.xcconfig.template Config/Local.xcconfig
   ```

   ```
   DEVELOPMENT_TEAM = ABCDE12345
   BUNDLE_ID_PREFIX = com.yourname
   ```

   - `DEVELOPMENT_TEAM` is your 10-character Team ID. Find it in Xcode → Settings → Accounts → your Apple ID → the team, or at [developer.apple.com/account](https://developer.apple.com/account) under Membership details.
   - `BUNDLE_ID_PREFIX` must be unique to you; the app's bundle ID becomes `<prefix>.logos`.
   - `Config/Local.xcconfig` is git-ignored. Don't set signing in the project file; all build settings live in `Config/*.xcconfig`.

2. **Prepare the iPhone.** Connect it by cable (or pair it over Wi-Fi in Xcode → Window → Devices and Simulators), unlock it and tap *Trust This Computer*. Turn on Developer Mode in Settings → Privacy & Security → Developer Mode and restart when asked.

3. **Build and run.** Open `Logos.xcodeproj`, choose the `Logos` scheme and your iPhone as the run destination, and press Run. Xcode creates the provisioning profile automatically (signing is Automatic).

4. **Trust the developer certificate** (first install with a free account only): on the iPhone, Settings → General → VPN & Device Management → your Apple ID → Trust.

5. **Sign in** with your Server's `https://` address, username and password, then pick the Library.

Notes:

- With a free Apple ID the installed app expires after 7 days; run it from Xcode again to renew it. Your data survives reinstalling over the top.
- The `Logos` scheme runs the Debug build. To judge battery, smoothness or performance, run a Release build without the debugger: Product → Scheme → Edit Scheme → Run → Build Configuration *Release*, and untick *Debug executable*. See [docs/performance-budgets.md](docs/performance-budgets.md).

### From the command line

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcrun devicectl list devices                     # find your iPhone's name or identifier

xcodebuild build \
    -project Logos.xcodeproj -scheme Logos -configuration Release \
    -destination "platform=iOS,name=<your iPhone>" \
    -derivedDataPath .build/DerivedData \
    -allowProvisioningUpdates

xcrun devicectl device install app --device "<your iPhone>" \
    .build/DerivedData/Build/Products/Release-iphoneos/Logos.app
xcrun devicectl device process launch --device "<your iPhone>" <BUNDLE_ID_PREFIX>.logos
```

## Project layout

- `Logos.xcodeproj` / `Logos/`: a thin app target (entitlements, Info, signing, `@main`) that wires everything together.
- `LogosKit/`: a local Swift package holding every module: `Domain`, `ServerAPI`, `Store` (GRDB), `Sync`, `Downloads`, `Playback` and `UI`. Allowed dependencies between them are listed in `LogosKit/Package.swift` and enforced by `scripts/check-module-graph.sh`.
- `LogosUITests/`: the XCUITest smoke test and performance tests.
- `Config/`: all build settings (`*.xcconfig`), `Info.plist` and entitlements.
- `docs/adr/`: architecture decisions. `docs/performance-budgets.md`: the performance budgets.

The only third-party dependency is [GRDB](https://github.com/groue/GRDB.swift); packages resolve only from the checked-in `LogosKit/Package.resolved`.

## Checks and tests

| Command | What it does |
|---|---|
| `scripts/format.sh` | swift-format lint (strict); `--fix` rewrites |
| `scripts/check-module-graph.sh` | checks the module graph and dependency policy |
| `scripts/test.sh` | builds the app and runs every LogosKit unit test on the simulator (`DEVICE`, default `iPhone 18 Pro`); pass e.g. `-only-testing:DomainTests` to narrow |
| `scripts/integration-test.sh` | runs ServerAPI and Sync against a throwaway audiobookshelf in Docker |
| `scripts/integration-test.sh --ui` | runs the UI smoke test (sign in, browse, download, play) against the same Server |
| `scripts/integration-test.sh --serve` | starts and seeds the Docker Server and prints its address, for manual poking |

CI runs the first three on every pull request. More detail on the tests, test launches and contribution rules is in [CLAUDE.md](CLAUDE.md).
