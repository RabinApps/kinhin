---
title: How to run fastlane screenshots in CI on a Mac
description: Run the fastlane screenshots lane on a kinhin runner and keep the PNGs as a CI artifact, since the VM is deleted when the job ends.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-to-run-fastlane-screenshots-in-ci-on-a-mac.html
---

# How to run fastlane screenshots in CI on a Mac

Screenshot capture needs a Mac: iOS screenshots come from simulators, and Xcode runs only on macOS. kinhin provides that Mac
as a runner, and the workflow runs the `screenshots` lane on it. The VM is deleted when the job ends, so the workflow also
uploads the PNGs as an artifact. Without that step the screenshots disappear with the VM.

## Steps

1. **Set up the fleet.** Install kinhin and start the runner as in
   [How to run GitHub Actions on a self-hosted Mac](/how-to-run-github-actions-on-a-self-hosted-mac).
2. **Add the screenshot settings.** Set the repository variables under **Settings**, then **Secrets and variables**, then
   **Variables**. `SNAPSHOT_LANGUAGES` sets the iOS languages and defaults to `en-US`.
3. **Run the lane by hand.** Start the mobile workflow and choose `screenshots` as the lane.
4. **Download the screenshots.** When the run finishes, open its page and download the `ios-screenshots` artifact. It is kept
   for 14 days.

The artifact is visible to everyone who can read the workflow run. Use test accounts and fake data on the screens the lane
captures.

## What has been verified

The iOS lane has been run locally on a simulator. The Android job needs an Android emulator on the runner, and the runner
image has to provide it. That setup has not been verified on a runner yet.

The [Store screenshots](/guide/mobile-screenshots) page has every workflow variable and the artifact details.

<SearchNextSteps />
