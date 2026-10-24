# Does Xcode Cloud build Logos as it is?

Research for [#66](https://github.com/kracobsen/logos/issues/66) (part of [#64](https://github.com/kracobsen/logos/issues/64)). Researched 2026-10-24 against Apple's Xcode Cloud documentation (developer.apple.com/documentation/xcode/xcode-cloud and its subpages), the Xcode Cloud release notes, the repo at `14f54ed`, and local `xcodebuild` runs (Xcode 27.1, 27A9275) in a fresh clone that had no `Config/Local.xcconfig`.

Legend: **[verified]** means checked against a primary source cited inline or reproduced locally. **[unverified]** means I couldn't confirm it at the source, so treat it as a lead.

## Answer

**Almost.** The repo already meets Apple's documented project requirements: a shared scheme with the archive action, automatic signing, public Swift package dependencies only, no third-party tools, and no project generation. An unsigned Release archive of the `Logos` scheme succeeds from a clean clone with automatic package resolution disabled. Three things need attention:

1. **Required: commit the team and bundle-ID prefix** (already planned). Without `Local.xcconfig`, a clone resolves the bundle ID to `local.dev.logos` and `DEVELOPMENT_TEAM` to empty. Xcode uses that resolved bundle ID to find the Xcode Cloud product, and the bundle ID is also the App Store Connect app record.
2. **Risk, cheap to hedge: the `Package.resolved` location.** Apple says the file must live at `Logos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. The repo only has `LogosKit/Package.resolved`. Local `xcodebuild` (27.1) accepts that file, but Xcode Cloud's own check isn't documented beyond the quoted path. The first cloud build will show whether it matters.
3. **Pick the Xcode version explicitly.** The project needs Xcode 27 (iOS 27 SDK, `swift-tools-version: 6.4`). Apple's public release notes stop at Xcode 26.2, so the 27.x versions on offer can only be read from the workflow's Environment picker.

You don't need `ci_scripts/`.

---

## 1. Repo facts [verified, from the repo]

- **Schemes are shared.** `Logos.xcodeproj/xcshareddata/xcschemes/` contains `Logos`, `LogosUITests` and `LogosPerformance`, all tracked in git. `xcuserdata/` is git-ignored.
- **The `Logos` scheme archives.** Its `BuildActionEntry` for `Logos.app` has `buildForArchiving = "YES"`, and `ArchiveAction` uses `buildConfiguration = "Release"`. Its test action runs the seven LogosKit unit-test targets in Debug.
- **Archivable products.** `xcodebuild -project Logos.xcodeproj -describeAllArchivableProducts -json` is the command Apple says Xcode uses to find Xcode Cloud products ([Configuring your first workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow#Select-the-archive-action)). Run in a clean clone, it lists the app as `Logos`, `productType: app`, `bundleIdentifier: local.dev.logos`, scheme `Logos`, "Any iOS Device". It also lists library products for the auto-generated `LogosKit` package scheme, which you can ignore.
- **Project file.** `objectVersion = 77` with `PBXFileSystemSynchronizedRootGroup` (buildable folders), `LastUpgradeCheck = 2700`, and one `XCLocalSwiftPackageReference` (`relativePath = LogosKit`). It has no shell-script build phases. The project is static and checked in, not generated.
- **Packages.** `LogosKit/Package.swift` uses `swift-tools-version: 6.4`, and its only remote dependency is `https://github.com/groue/GRDB.swift.git` (public). `LogosKit/Package.resolved` (version 3) pins GRDB 7.11.1 at `b83108d…`. There is **no** `Logos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.
- **Signing.** `Config/Base.xcconfig` sets `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM =` (empty), `BUNDLE_ID_PREFIX = local.dev`, `PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_PREFIX).logos`, and ends with `#include? "Local.xcconfig"`. `Config/Local.xcconfig` is git-ignored. The entitlements file is an empty dict. Background audio comes from `UIBackgroundModes` in `Config/Info.plist`, so the App ID needs no extra capability.
- **Build number.** The xcconfig sets `CURRENT_PROJECT_VERSION = 1` and `MARKETING_VERSION = 0.1`.
- **Strictness.** Warnings are errors for both the app (`SWIFT_TREAT_WARNINGS_AS_ERRORS`, `GCC_TREAT_WARNINGS_AS_ERRORS`) and the package (`.treatAllWarnings(as: .error)`).

## 2. Does the archive build at all? [verified locally, Xcode 27.1]

In a fresh worktree of `main` with no `Local.xcconfig`, this command succeeded with no diagnostics and produced `Logos.xcarchive/Products/Applications/Logos.app`:

```
xcodebuild archive -project Logos.xcodeproj -scheme Logos -destination generic/platform=iOS \
  -archivePath /tmp/xcc-out/Logos.xcarchive -disableAutomaticPackageResolution CODE_SIGNING_ALLOWED=NO
```

So the Release configuration compiles under warnings-as-errors and the package graph resolves offline from the pins. This doesn't test cloud signing, and it ran on 27.1, not 27.0. GitHub Actions CI already builds on 27.0, but only Debug for the simulator.

## 3. Shared scheme and archive action [verified]

The project requirements in [Setting up your project to use Xcode Cloud](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud) are:

- "Use a consistent Xcode project or workspace."
- "Use shared schemes."
- "Enable the archive action for the scheme that builds your app or framework."
- Make dependencies available to Xcode Cloud.
- "Allow Xcode to manage signing for you."
- "Set the bundle identifier for your app target in the Signing & Capabilities pane… If you use `.xcconfig` files to set the bundle identifier, see [Configuring your first workflow]."

[Resolving common configuration and build issues](https://developer.apple.com/documentation/xcode/resolving-common-configuration-and-build-issues) adds: "If a workflow's action doesn't list a scheme, make sure you shared the scheme." An archive action "runs the `xcodebuild archive` command" ([Configuring your workflow's actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions)).

**Logos already meets these.** Choose the `Logos` scheme for archive and test actions. Don't use `LogosPerformance` for archiving: its archive action is Release, but the scheme exists for the Performance configuration.

## 4. Swift package resolution [verified, with one open point]

[Making dependencies available to Xcode Cloud](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud#Use-Swift-package-dependencies-and-Git-submodules) says:

> Xcode Cloud doesn't use automatic package resolution and instead relies on the `Package.resolved` file to resolve your dependencies. … make sure to include the `Package.resolved` file in your Git repository … Additionally, make sure the `Package.resolved` file resides at `$filename.xcodeproj/project.workspace/xcshareddata/swiftpm/Package.resolved`.

> Forcing Xcode Cloud to use automatic package resolution — for example, by changing settings in a custom build script — may result in undefined behavior and failing builds.

Public packages need no extra setup ("Xcode Cloud supports Swift packages … without any separate configuration if their repositories are publicly accessible"). [Building Swift packages or apps that use them in CI](https://developer.apple.com/documentation/xcode/building-swift-packages-or-apps-that-use-them-in-continuous-integration-workflows) gives the same `.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/` path, and [Resolving common issues](https://developer.apple.com/documentation/xcode/resolving-common-configuration-and-build-issues#Resolve-Swift-package-dependency-issues) calls a missing `Package.resolved` "a common cause of failing builds".

**What `xcodebuild` actually does here [verified locally].**

- `xcodebuild -resolvePackageDependencies -disableAutomaticPackageResolution` on a fresh clone resolves GRDB 7.11.1 from `LogosKit/Package.resolved`. It doesn't create the workspace-level file. GitHub Actions has relied on this all along (`scripts/test.sh` passes the same flag).
- With `LogosKit/Package.resolved` temporarily removed, it fails with: "a resolved file is required when automatic dependency resolution is disabled and should be placed at `…/Logos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`."

So Xcode treats the local root package's resolved file as the project's, but the location it advertises (and the one Apple documents for Xcode Cloud) is the workspace one.

**[unverified]** Whether Xcode Cloud checks for the workspace-level file itself before running `xcodebuild` is undocumented. If it just runs `xcodebuild` with resolution disabled, today's layout works. The options are:

- **(a) Try it as is.** The first build answers the question. If it fails, the log says so in the "Resolve dependencies" step, which comes before any compile.
- **(b) Hedge.** Also commit `Logos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Two pin files can drift, so `scripts/check-module-graph.sh` (or CI) would have to assert they're identical. A symlink is another option. Its behaviour under Xcode Cloud's clone is untested, and the docs only mention symlinks for `ci_scripts` ([Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts#Add-resources-to-the-CI-scripts-directory)).

I'd recommend (a), falling back to (b) only if the first build fails.

## 5. Signing [verified docs; cloud behaviour unverified until the first build]

- Xcode Cloud requires automatic signing ("Allow Xcode to manage signing for you", see section 3). Logos uses `CODE_SIGN_STYLE = Automatic`.
- Signing for distribution is decided by the archive action's **Deployment Preparation** setting: None, "TestFlight (Internal Testing Only)", or "TestFlight and App Store". In Apple's words, it "determines how Xcode Cloud signs your app" ([Configuring your workflow's actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions#Add-an-archive-action)). Distribution uses cloud-managed certificates: "Xcode uses cloud-managed signing certificates to automatically code sign your app. These signing certificates are associated with your Apple Developer Account" ([Distributing your app](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)). No certificates or profiles go in the repo or in scripts.
- An app record in App Store Connect is required. Xcode offers to create one during onboarding (App Manager, Admin or Account Holder role) ([Configuring your first workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow#Create-an-app-record)).
- **xcconfig-defined bundle IDs.** Apple's note in [Configuring your first workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow#Review-Xcode-Cloud-workflows) says: "If you use `.xcconfig` files to set the bundle identifier … First, set the bundle identifier for your app target in the Signing & Capabilities pane… Note that you need to use App Store Connect to view your workflows and builds because Xcode relies on the explicitly set bundle identifier to show them." Once `BUNDLE_ID_PREFIX` is committed, the resolved ID is fixed, and `-describeAllArchivableProducts` (which Xcode uses for onboarding) reports it. **[unverified]** Whether Xcode's Cloud UI then shows workflows normally, or whether you'd need App Store Connect for that, is undocumented. Either way it's a UI inconvenience, not a build failure. Don't move the bundle ID into the project file: CLAUDE.md keeps build settings out of it.
- Known onboarding issue (Xcode Cloud release notes, 2024-11-06): "Some bundle IDs aren't automatically registered when onboarding to Xcode Cloud." The workaround is to archive and export once locally, or to register the ID under Certificates, Identifiers & Profiles ([release notes](https://developer.apple.com/xcode-cloud/release-notes/)).
- Builds for external TestFlight need the workflow's **Clean** option ("distributing a new version to external testers with TestFlight requires a clean build", [Workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference#Perform-a-clean-build)).

## 6. Xcode versions [partly unverified]

- The workflow's Environment section lets you "choose from available Xcode and macOS versions". Xcode suggests the latest *released* versions for a first workflow, and Apple "may periodically update available macOS and Xcode versions and ask you to update your workflows" ([Workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference#Environment), [Configuring your first workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow#Review-the-suggested-workflow)). Custom aliases let workflows share one Xcode/macOS choice ([release notes](https://developer.apple.com/xcode-cloud/release-notes/), 2024-02-27).
- **[unverified]** The public [Xcode Cloud release notes](https://developer.apple.com/xcode-cloud/release-notes/) last list an Xcode release on 2025-12-19 (Xcode 26.2), and their newest entry is from 2026-02-10. They say nothing about Xcode 26.3+ or 27.x. Past practice in those notes has been to add each Xcode release and beta, including x.0 on release day, and to retire old ones. Xcode 27.0 is very likely offered, but I couldn't confirm it at a primary source. WWDC26 "What's new in Xcode 27" ([session 258](https://developer.apple.com/videos/play/wwdc2026/258/)) shows the faster Xcode Cloud onboarding in Xcode 27, but lists no versions.
- The project needs Xcode 27.x: the iOS 27 deployment target needs the iOS 27 SDK, and `swift-tools-version: 6.4` needs Swift 6.4. Pin the workflow to **Xcode 27.0** to match GitHub Actions (`.github/workflows/ci.yml` pins `/Applications/Xcode_27.0.app`), or to "Latest Release" if you accept drift. Either way, don't use a beta for archiving. Apple also requires Xcode 15 or later to set up Xcode Cloud, which is no constraint here.

## 7. Private GitHub repo [verified]

GitHub (cloud and Enterprise) is a supported provider. Connecting it needs organization-owner rights, or admin permission on a personal repo ([Setting up your project](https://developer.apple.com/documentation/xcode/setting-up-your-project-to-use-xcode-cloud#Use-a-remote-source-control-repository)). Making the repo private changes nothing else. GRDB is public, so no extra repository grant is needed ([Making dependencies available](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud#Grant-Xcode-Cloud-access-to-private-dependencies)).

## 8. `ci_scripts/` [verified: not needed]

- Custom scripts (`ci_post_clone.sh`, `ci_pre_xcodebuild.sh`, `ci_post_xcodebuild.sh`) live in `ci_scripts/`, "located in the same directory as your Xcode project" (here, the repo root). They're for installing tools, extra dependencies, uploading artifacts and similar jobs ([Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)). Logos has no third-party tools and no CocoaPods or Carthage, and Xcode handles packages, so nothing calls for one.
- **Build numbers need no script.** "Xcode Cloud assigns a build number to each build… starting from `1`", and App Store Connect uses it for TestFlight and App Store builds ([Setting the next build number](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds)). `CI_BUILD_NUMBER` is available to scripts if ever needed ([Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference)). `CURRENT_PROJECT_VERSION = 1` can stay. Bump `MARKETING_VERSION` per release as usual.
- Possible later uses (all optional): running `scripts/format.sh` or `scripts/check-module-graph.sh` in `ci_post_clone.sh`. GitHub Actions already covers both, so duplicating them only costs compute hours.
- Don't add a script that turns automatic package resolution back on (see the "undefined behavior" note in section 4).

## Concrete changes

| # | Change | Required? |
|---|---|---|
| 1 | Commit `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` in `Config/Base.xcconfig` (keeping `#include? "Local.xcconfig"` as an optional local override is harmless, since `#include?` skips a missing file), and update `Local.xcconfig.template`, the README and CLAUDE.md to match. | **Yes.** Without it, cloud builds see `local.dev.logos` with no team. |
| 2 | Before onboarding, create the App Store Connect app record and register the bundle ID (`<prefix>.logos`), or let Xcode do it. If onboarding doesn't register it, archive and export once locally. | Yes (account setup, not a repo change) |
| 3 | In the workflow, pick the `Logos` scheme, an archive action for iOS, and Xcode 27.0 (or a custom alias). Enable Clean for external TestFlight. | Yes (workflow setup) |
| 4 | Commit `Logos.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (identical to `LogosKit/Package.resolved`) and add a check that the two match. | Only if the first build fails in dependency resolution |
| 5 | `ci_scripts/` | No |
