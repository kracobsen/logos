# Xcode Cloud: manual-only workflows, how builds start, build numbers, TestFlight and cost

Findings for #65 (part of #64). Researched 2026-10-24 against Apple's current Xcode Cloud docs, the App Store Connect API reference and WWDC sessions up to WWDC26. Nothing here was tried against a real Xcode Cloud account.

## Sources

- [SC] Xcode docs, [Configuring start conditions](https://developer.apple.com/documentation/xcode/configuring-start-conditions).
- [WR] Xcode docs, [Xcode Cloud workflow reference](https://developer.apple.com/documentation/xcode/xcode-cloud-workflow-reference).
- [DIST] Xcode docs, [Creating a workflow that builds your app for distribution](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution).
- [TF] Xcode docs, [Distributing your Xcode Cloud builds through TestFlight](https://developer.apple.com/documentation/xcode/distributing-your-xcode-cloud-builds-through-testflight).
- [ACT] Xcode docs, [Configuring your Xcode Cloud workflow's actions](https://developer.apple.com/documentation/xcode/configuring-your-xcode-cloud-workflow-s-actions).
- [BN] Xcode docs, [Setting the next build number for Xcode Cloud builds](https://developer.apple.com/documentation/xcode/setting-the-next-build-number-for-xcode-cloud-builds).
- [ENV] Xcode docs, [Environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference).
- [FIRST] Xcode docs, [Configuring your first Xcode Cloud workflow](https://developer.apple.com/documentation/xcode/configuring-your-first-xcode-cloud-workflow).
- [NOTES] Xcode docs, [Including notes for testers with a beta release of your app](https://developer.apple.com/documentation/xcode/including-notes-for-testers-with-a-beta-release-of-your-app).
- [USAGE] Xcode docs, [Reviewing Xcode Cloud usage data](https://developer.apple.com/documentation/xcode/reviewing-xcode-cloud-usage-data).
- [IVB] Xcode docs, [Understanding infrastructure validation builds](https://developer.apple.com/documentation/xcode/understanding-infrastructure-validation-builds).
- [API] App Store Connect API, [Xcode Cloud workflows and builds](https://developer.apple.com/documentation/appstoreconnectapi/xcode-cloud-workflows-and-builds), [POST /v1/ciBuildRuns](https://developer.apple.com/documentation/appstoreconnectapi/post-v1-cibuildruns), [CiBuildRunCreateRequest](https://developer.apple.com/documentation/appstoreconnectapi/cibuildruncreaterequest), [CiWorkflow attributes](https://developer.apple.com/documentation/appstoreconnectapi/ciworkflow/attributes-data.dictionary), [CiManualBranchStartCondition](https://developer.apple.com/documentation/appstoreconnectapi/cimanualbranchstartcondition), [CiBranchPatterns](https://developer.apple.com/documentation/appstoreconnectapi/cibranchpatterns), [CiBuildRun attributes](https://developer.apple.com/documentation/appstoreconnectapi/cibuildrun/attributes-data.dictionary).
- [ASC-IT] App Store Connect Help, [Add internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/).
- [PRICE] [Xcode Cloud overview](https://developer.apple.com/xcode-cloud/) and [Get started with Xcode Cloud](https://developer.apple.com/xcode-cloud/get-started/).
- [W21] WWDC21 10267, [Meet Xcode Cloud](https://developer.apple.com/videos/play/wwdc2021/10267/).
- [W23] WWDC23 10224, [Simplify distribution in Xcode and Xcode Cloud](https://developer.apple.com/videos/play/wwdc2023/10224/).
- [W24] WWDC24 10200, [Extend your Xcode Cloud workflows](https://developer.apple.com/videos/play/wwdc2024/10200/).
- [W26] WWDC26 261, [Build, deliver, and automate with Xcode Cloud](https://developer.apple.com/videos/play/wwdc2026/261/).
- [REPO] This repo: `Config/Base.xcconfig`, `Config/Local.xcconfig.template`.

## Short answers

| Question | Answer |
|---|---|
| Manual-only workflow? | Yes. Give the workflow a **Manual Start** condition and remove every other start condition. Then it "can now only be started when I tell it to and not from any other events." [SC] [W24] |
| Ways to start it | Xcode (Report navigator, Cloud tab, Control-click the workflow, Start Build, pick a branch), the Xcode Cloud tab on App Store Connect web, and `POST /v1/ciBuildRuns` in the App Store Connect API from any terminal or script. [W21] [TF] [API] No first-party CLI (`xcodebuild` has no Xcode Cloud command), and webhooks only report outward. [W26] |
| Restrict to `main`? | Yes. Set the Manual Start condition's branch to the custom branch `main` (in the API: `manualBranchStartCondition.source` with `isAllMatch: false` and the exact pattern `main`, `isPrefix: false`). Manual starts and API starts are only accepted for references that match a manual start condition. [SC] [API] [W24] |
| Build number | Xcode Cloud numbers every build run with an integer, counting up from 1 (or from a "Next Build Number" you set in App Store Connect). The upload to App Store Connect and TestFlight carries that number. Scripts see it as `CI_BUILD_NUMBER`. [BN] [ENV] |
| Internal TestFlight | An Archive action with Deployment Preparation **TestFlight (Internal Testing Only)**, plus a **TestFlight Internal Testing** post-action that names an internal tester group. The group has to exist in App Store Connect first. [ACT] [DIST] [TF] [W23] |
| Free tier | 25 compute hours a month come with the Developer Program. They don't roll over. Paid tiers are 100 h for US$49.99, 250 h for $99.99, 1,000 h for $399.99 and 10,000 h for $3,999.99 a month. [PRICE] |
| Cost of an archive-only build | Apple doesn't publish a figure. My estimate for an app this size is about 5 to 15 minutes per run, so 0.1 to 0.25 compute hours, or roughly 100 to 250 builds a month on the free tier. Measure the first few runs (see below). |

## 1. Manual-only workflows

- Start conditions are Branch Changes, Pull Request Changes, Tag Changes, On a Schedule for a Branch, and **Manual Start**: "Xcode Cloud starts a new build when you manually request it." [SC]
- "To support starting a build manually without tying it to a Git event or a schedule, add a Manual Start condition and configure the specific branches, tags, and pull requests to which it applies." [SC]
- WWDC24 shows the manual-only setup directly: "Next, I'll add a Manual Start condition and remove the existing one. This workflow can now only be started when I tell it to and not from any other events. I'll accept the default option to associate the start condition with any branch but I could also specify a branch, PR or git tag..." Manual start conditions are "new in Xcode 15.1". [W24]
- The API models this as three optional workflow attributes, `manualBranchStartCondition`, `manualTagStartCondition` and `manualPullRequestStartCondition`, alongside the automatic `branchStartCondition`, `tagStartCondition`, `pullRequestStartCondition` and `scheduledStartCondition`. A manual-only workflow sets only the manual ones. [API CiWorkflow attributes]
- A new workflow defaults to Branch Changes on the default branch, and Xcode's first-workflow sheet "starts a build on every change to your `main` branch". Turning that off is a deliberate edit. [SC] [FIRST]
- Outdated advice: [DIST] still says "If you want to start a build for the workflow manually, configure a start condition that never actually starts a build." That was the workaround from before Xcode 15.1. Manual Start replaces it.
- WWDC26 "Set Up Distribution" creates "a new distribution workflow ... for internal TestFlight, ready for me to start anytime". That suggests the generated distribution workflow is manual-start by default, but the session doesn't show its start conditions, so check after creating it. [W26] [TF]
- A build with `[ci skip]` in the latest commit's title or message is skipped. That only matters for automatic conditions. [SC]

## 2. Ways to start a build

1. **Xcode**: Report navigator, Cloud tab, then right-click (Control-click) the workflow, choose **Start Build**, pick a branch and confirm. [W21] [W23] [TF]
2. **App Store Connect web**: the app's Xcode Cloud tab handles "starting and viewing builds, managing workflows". [W21] Once the first build has run, workflows can be edited in Xcode or App Store Connect, but the first setup has to happen in Xcode. [SC] [WR]
3. **App Store Connect API**: `POST https://api.appstoreconnect.apple.com/v1/ciBuildRuns` "Start a new Xcode Cloud build for a workflow." [API]
   - Body (`CiBuildRunCreateRequest`): `data.type = "ciBuildRuns"`, `attributes.clean` (optional Boolean), and the relationships `workflow` (a `ciWorkflows` id), `sourceBranchOrTag` (a `scmGitReferences` id), `pullRequest`, or `buildRun` (rebuild an earlier run). Apple's minimal example sends only `workflow`. [API]
   - The response is a `ciBuildRuns` resource with `number` ("The Xcode Cloud build number"), `executionProgress: "PENDING"` and `startReason: "MANUAL"`. Other `startReason` values include `MANUAL_REBUILD`, `GIT_REF_CHANGE`, `PULL_REQUEST_OPEN`, `PULL_REQUEST_UPDATE` and `SCHEDULE`. [API]
   - "Builds started by the App Store Connect API are considered manual, therefore you should ensure that you have a manual start condition setup that matches the reference you're building." [W24]
   - Finding the ids: `GET /v1/ciProducts` then the product's workflows gives the workflow id. The workflow's repository `gitReferences` give the id of `refs/heads/main`. [API, topics "Products", "Workflows", "Git References"]
   - Authentication uses a standard App Store Connect API key (a signed JWT). Creating and holding that key is a human task. It is a credential, so an agent shouldn't read it. Apple's docs reviewed here don't say which minimum key role can create build runs. Check that when the key is made.
4. **Nothing else that's first-party.** Webhooks (WWDC26) fire on build created, started and completed, so they report outward and don't start anything. [W26] Rebuilding an existing run (Xcode or API `buildRun`) counts as `manual_rebuild`. [ENV] [API]

A build script can tell how it was started from `CI_START_CONDITION` (`manual`, `manual_rebuild`, `push`, `pr_open`, `pr_update`, `schedule`), and which branch from `CI_BRANCH`. [ENV]

## 3. Restricting starts to `main`

- In Xcode or App Store Connect, set the Manual Start condition to Custom Branches and enter `main`. Branch matching can be exact or "Branches beginning with ..." [SC]
- In the API, `CiManualBranchStartCondition.source` is a `CiBranchPatterns`: `isAllMatch: false` plus `patterns: [{ "pattern": "main", "isPrefix": false }]`. Patterns are case sensitive. With `isPrefix: false`, the branch name must match exactly. [API]
- Leave out `manualTagStartCondition` and `manualPullRequestStartCondition` so tags and PRs can't be built by hand.
- Belt and braces (my suggestion, not from Apple): have `ci_scripts/ci_post_clone.sh` exit non-zero unless `CI_BRANCH` is `main`. That catches a workflow edited by mistake later.

## 4. Build numbers

- "Xcode Cloud assigns a build number to each build it performs. A build number is an integer value that Xcode Cloud automatically increases with each build, starting from `1`." Numbers are always integers, never hashes or timestamps. [BN]
- "When you distribute an Xcode Cloud build with TestFlight or release it on the App Store, App Store Connect uses the build number of the Xcode Cloud build", for example `1.2.1 (42)`. So `CFBundleVersion` in the upload is Xcode Cloud's number. `CURRENT_PROJECT_VERSION = 1` in `Config/Base.xcconfig` doesn't need bumping for Xcode Cloud uploads. `MARKETING_VERSION` (`CFBundleShortVersionString`) still comes from the project. [BN] [REPO]
- iOS only needs each (version, build) pair to be unique, so restarting at 1 under a new marketing version is fine. Only macOS needs the build number to keep rising across versions. [BN]
- **Next Build Number**: App Store Connect, the app, Xcode Cloud tab, Settings, Build Number tab, Edit next to Next Build Number. Only Admin or App Manager roles can change it. Use it if TestFlight already has local uploads with higher numbers under the same marketing version, so the numbers don't collide. [BN]
- `CI_BUILD_NUMBER` ("The number of the current build, for example, `42`") is available to `ci_scripts`. [ENV]
- Inference, not stated outright by Apple: the counter belongs to the product (the setting is per app), and every build run takes a number. Runs from other workflows, and failed runs, leave gaps in the TestFlight sequence. The API's `ciBuildRuns.number` is the same number. [BN] [API]

## 5. Delivering to internal TestFlight testers

1. In App Store Connect, create an internal tester group (TestFlight, the + next to Internal Testing) and add up to 100 App Store Connect users. [ASC-IT] [TF]
2. In the workflow, add an **Archive** action (iOS, scheme `Logos`). Archive is required for any TestFlight upload. Set **Deployment Preparation** to **TestFlight (Internal Testing Only)**: "eligible for distribution to testers with TestFlight ... isn't eligible for release on the App Store". [ACT]
3. Add a **TestFlight Internal Testing** post-action and choose the group. "The people or groups you add receive the update on their test device." [DIST] [W23]
4. App Store Connect marks these builds as internal. They can only go to internal groups, never to external testing or the App Store. [ASC-IT]
5. The **post-action is how Xcode Cloud builds reach a group**. App Store Connect's own "Enable automatic distribution" on a group doesn't cover them: "You must always manually add builds created by Xcode Cloud to groups in App Store Connect." In other words, either the workflow's post-action adds the build or a person does. [ASC-IT]
6. Optional: `TestFlight/WhatToTest.en-US.txt` next to the project (written by hand or generated in `ci_post_xcodebuild.sh`) fills the "What to Test" field. [NOTES] [W23]

Other settings: [DIST] tells distribution workflows to turn on **Restrict Editing** and **Clean**. Restrict Editing is required only for builds eligible for App Review. Clean is required only for *external* TestFlight, and it "significantly increases the time it takes to perform a build". [WR] [DIST] For internal-only builds, both are optional. Leaving Clean off saves compute.

## 6. Free tier and cost of an archive-only build

- "Apple Developer Program membership includes 25 compute hours per month." Unused hours don't roll over. The Account Holder buys more in the Apple Developer app. [PRICE]
- "A compute hour is an hour of time used to execute a specific task in the cloud ... running 5 tests of 12 minutes each equals one compute hour." Usage is the sum of action times. It isn't wall-clock time, because actions run in parallel. [PRICE] [USAGE]
- Infrastructure validation builds that Apple sometimes runs alongside yours don't "consume your build minutes". [IVB]
- Usage is shown in App Store Connect (Users and Access, Xcode Cloud tab, team-wide; or the app's Xcode Cloud tab, per app, with CSV export) and in the Apple Developer app. [USAGE]
- **Estimate (mine, not Apple's):** one Release archive of the `Logos` app with its local `LogosKit` package and GRDB, cached (not Clean), probably takes about 5 to 15 minutes including clone, package resolution, archive, export and upload. That's about 0.1 to 0.25 compute hours, so 25 hours covers roughly 100 to 250 such builds a month. A manual build a few times a week would use a few percent of the allowance. A Clean build or an added test action would cost more. To get a real number, compare the first runs with App Store Connect's usage page and record it here.

## Repo-specific blocker found while researching

Xcode Cloud clones the repo, so the git-ignored `Config/Local.xcconfig` won't be there. `Config/Base.xcconfig` then falls back to `DEVELOPMENT_TEAM =` (empty) and `BUNDLE_ID_PREFIX = local.dev`, giving the bundle ID `local.dev.logos`, which won't match the App Store Connect app record. [REPO] Apple also warns that a bundle ID set through `.xcconfig` needs extra steps. Set it explicitly in Signing & Capabilities before the first workflow, and expect to view workflows in App Store Connect because Xcode relies on the explicit bundle ID. [FIRST]

Possible fix, for #64 to decide: a `ci_scripts/ci_post_clone.sh` that writes `Config/Local.xcconfig` from `CI_TEAM_ID` [ENV] and a workflow environment variable for the bundle-ID prefix. Neither value is secret. Or commit the real prefix. Either way, keep the "build settings only in `Config/*.xcconfig`" rule.

## Open points (not verifiable from docs)

- Whether App Store Connect accepts saving a workflow with **zero** start conditions. The docs only describe a Manual Start condition, and the manual-only setup in WWDC24 still has one.
- The minimum App Store Connect API key role needed for `POST /v1/ciBuildRuns`.
- Actual compute minutes for a `Logos` archive.
