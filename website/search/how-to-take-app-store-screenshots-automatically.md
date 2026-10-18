---
title: How to take App Store screenshots automatically
description: Write UI tests once, then let fastlane capture your App Store screenshots from them. kinhin adds the lane, the settings and the sample tests.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-to-take-app-store-screenshots-automatically.html
---

# How to take App Store screenshots automatically

Take the screenshots from UI tests instead of a simulator you tap through by hand. A UI test opens each screen and saves a
screenshot at the point you choose. fastlane runs the tests, so the same screenshots come out again each time the app
changes. On iOS the tool is `snapshot`; on Android it is `screengrab`.

kinhin writes the wiring: a `screenshots` lane, the settings files and sample tests.

## Steps

1. **Add the lane.** Run `kinhin mobile init` in your project. It writes the settings, the sample tests and the lane. It does
   not edit your Xcode project or your Gradle files.
2. **Add a UI test target (iOS, once).** In Xcode, add a UI Testing Bundle target. The
   [iOS setup steps](/guide/mobile-screenshots#ios-set-up-the-ui-test-target) show each click.
3. **Write the tests.** Replace the sample tests with tests that open your screens. Call `snapshot("01-home")` on iOS or
   `Screengrab.screenshot("01-home")` on Android at each screen.
4. **Run the lane.** From the folder that holds `fastlane/`, run `bundle exec fastlane screenshots`. On iOS you get one PNG
   per `snapshot` call and language, in `fastlane/screenshots/`.

Framing with frameit is optional. Uploading to the stores is off until you turn it on.

## What has been verified

The iOS lane has been run on an iPhone 17e simulator, and the output layout above is what it wrote. Read
[Store screenshots with fastlane](/guide/mobile-screenshots) for every setting and the Android details.

For a full walk-through, including the first build, see [Tutorial: first build](/guide/mobile-fastlane-tutorial).

<SearchNextSteps />
