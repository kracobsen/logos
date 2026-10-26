# Releases build on Xcode Cloud; PR CI stays on GitHub Actions

TestFlight builds are archived, signed and uploaded by an Xcode Cloud workflow that the human starts by hand, while every PR keeps running format, module-graph and unit-test checks on GitHub Actions. We chose this because the repo may go private, and the Apple Developer Program membership includes 25 free Xcode Cloud compute hours a month. Xcode Cloud also manages the signing certificates, so no signing secrets live in GitHub. The cost is two CI systems, and the release workflow's configuration lives in App Store Connect rather than in the repo; [docs/releasing.md](../releasing.md) records it.

## Considered Options

- **A release job on GitHub Actions with signing secrets.** Rejected: signing secrets to create and keep in GitHub, and macOS runner minutes on a repo that may go private.
