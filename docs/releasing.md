# Releasing

Releases go to TestFlight through Xcode Cloud, started by hand. PR CI stays on GitHub Actions; see [ADR 0002](adr/0002-releases-build-on-xcode-cloud.md). From [Prepare the repo for TestFlight releases from Xcode Cloud](https://github.com/kracobsen/logos/issues/72).

## The workflow

The workflow's configuration lives in App Store Connect, not in the repo. It is set up like this:

| Setting | Value |
|---|---|
| Name | TestFlight |
| Start condition | Manual Start, limited to the branch `main` |
| Environment | Xcode 27.0 (pinned, to match GitHub Actions) |
| Action | Archive: iOS, scheme `Logos`, configuration Release |
| Post-action | TestFlight Internal Testing to the group "Owner" |
| Post-action | Notify: email on failure ("All"), success "Don't notify" |

The repo side needs nothing beyond what's committed: the team and bundle prefix in `Config/Base.xcconfig` (bundle ID `no.kracobsen.logos`), `ITSAppUsesNonExemptEncryption = NO` in `Config/Info.plist` (the app's only encryption is HTTPS), and the shared `Logos` scheme. There are no `ci_scripts/`. Signing uses cloud-managed certificates.

If you change the workflow in App Store Connect, update this table. Whether Xcode Cloud offers Xcode 27.0, and whether it finds `LogosKit/Package.resolved` where it is, is settled by the first cloud build ([#73](https://github.com/kracobsen/logos/issues/73)).

## How to release

1. Merge what you want to ship to `main`.
2. Press Start Build: in Xcode, Report navigator → Cloud → Start Build; or in App Store Connect, the app's Xcode Cloud tab. A build always uses the head of `main`; it can't pick an older commit. To ship an older build again, redistribute it in TestFlight.
3. Optionally, once the build is in TestFlight, type "What to Test" for it in App Store Connect.

A successful build shows up in the TestFlight app on the iPhone. A failed one sends an email. Each build number is tied to its commit in Xcode Cloud.

## Versioning

Xcode Cloud sets the build number (`CURRENT_PROJECT_VERSION`) itself. The version (`MARKETING_VERSION` in `Config/Base.xcconfig`) is bumped by hand; the first build is version 0.1.

## What TestFlight builds are for

TestFlight builds are for daily listening. They don't replace a PR's manual device checklist or its performance measurements: those keep using builds installed from Xcode, because TestFlight only builds `main` and its Release build has no test launches. See [performance-budgets.md](performance-budgets.md).
