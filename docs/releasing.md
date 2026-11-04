# Releasing

Releases go to TestFlight through Xcode Cloud, started by hand. PR CI stays on GitHub Actions; see [ADR 0002](adr/0002-releases-build-on-xcode-cloud.md). From [Prepare the repo for TestFlight releases from Xcode Cloud](https://github.com/kracobsen/logos/issues/72).

## The workflow

The workflow's configuration lives in App Store Connect, not in the repo. It is set up like this:

| Setting | Value |
|---|---|
| Name | Default |
| Start condition | Manual Start, limited to the branch `main` |
| Environment | Xcode 27.0 (pinned, to match GitHub Actions) |
| Action | Archive: iOS, scheme `Logos`, configuration Release |
| Post-action | TestFlight Internal Testing to the group "Owner" |
| Post-action | Notify: email on failure ("All"), success "Don't notify" |

The repo side needs nothing beyond what's committed: the team and bundle prefix in `Config/Base.xcconfig` (bundle ID `no.kracobsen.logos`), `ITSAppUsesNonExemptEncryption = NO` in `Config/Info.plist` (the app's only encryption is HTTPS), and the shared `Logos` scheme. There are no `ci_scripts/`. Signing uses cloud-managed certificates.

If you change the workflow in App Store Connect, update this table. Whether Xcode Cloud offers Xcode 27.0, and whether it finds `LogosKit/Package.resolved` where it is, is settled by the first cloud build ([#73](https://github.com/kracobsen/logos/issues/73)).

## How to release

1. Merge what you want to ship to `main`.
2. Run `scripts/release.sh`. It fetches `origin/main`, shows the commit and version that will be built, asks, and starts the workflow through the App Store Connect API. `--wait` also waits for the build and fails if it does; `--yes` skips the question. Without the script, press Start Build: in Xcode, Report navigator → Cloud → Start Build; or in App Store Connect, the app's Xcode Cloud tab. A build always uses the head of `main` on GitHub, not your checkout; it can't pick an older commit. To ship an older build again, redistribute it in TestFlight.
3. Optionally, once the build is in TestFlight, type "What to Test" for it in App Store Connect.

A successful build shows up in the TestFlight app on the iPhone. A failed one sends an email. Each build number is tied to its commit in Xcode Cloud.

### The API key for `scripts/release.sh`

Once: in App Store Connect, Users and Access → Integrations → App Store Connect API, create a Team key with the App Manager role and download its `.p8` (it can only be downloaded once). Keep it outside the repo, at `~/.appstoreconnect/private_keys/AuthKey_<key ID>.p8`, and export these in your shell:

| Variable | Value |
|---|---|
| `ASC_KEY_ID` | the key's ID |
| `ASC_ISSUER_ID` | the issuer ID shown above the key list |
| `ASC_KEY_PATH` | optional; the `.p8` file if it isn't at the path above |

The script signs a short-lived token with the key (CryptoKit, in `scripts/release/start-build.swift`); the key never leaves your Mac. It finds the app by its bundle ID (from `Config/Base.xcconfig` on `origin/main`), the workflow by its name "Default" and the branch `main`, so renaming the workflow means changing `scripts/release.sh` too.

## Versioning

Xcode Cloud sets the build number (`CURRENT_PROJECT_VERSION`) itself. The version (`MARKETING_VERSION` in `Config/Base.xcconfig`) is bumped by hand; the first build is version 0.1.

## What TestFlight builds are for

TestFlight builds are for daily listening. They don't replace a PR's manual device checklist or its performance measurements: those keep using builds installed from Xcode, because TestFlight only builds `main` and its Release build has no test launches. See [performance-budgets.md](performance-budgets.md).
