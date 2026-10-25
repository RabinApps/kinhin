---
title: How to generate localized app store screenshots
description: List the languages once and fastlane captures your screenshots in each one, in its own folder. Works for iOS with snapshot and Android with screengrab.
head:
  - - link
    - rel: canonical
      href: https://kinhin.dev/how-to-generate-localized-app-store-screenshots.html
---

# How to generate localized app store screenshots

List the languages once. The screenshots lane runs your UI tests for each language and writes each set into its own folder.
The lane sets the language, but your app still has to show it: every language needs translated strings in the app, or each
locale shows the same text.

## Set the languages

- **iOS:** set `SNAPSHOT_LANGUAGES`, for example `en-US,fr-FR`, then run `bundle exec fastlane screenshots`.
- **Android:** set `SCREENGRAB_LOCALES` the same way.

```bash
SNAPSHOT_LANGUAGES=en-US,fr-FR bundle exec fastlane screenshots   # iOS
SCREENGRAB_LOCALES=en-US,fr-FR bundle exec fastlane screenshots   # Android
```

Each language gets its own folder, such as `fastlane/screenshots/fr-FR/` on iOS.

## Translate the strings

Add a translation for each language in the app itself. On iOS that is the string catalog or `Localizable.strings`. On Android
it is a `values-fr/strings.xml` folder next to `values/strings.xml`. Without these, the French screenshots show English text.

## What has been verified

In kinhin's own runs, both platforms captured `en-US` and `fr-FR` in one run, each in its own folder. Those runs used sample
apps that translate a single string, so the locale switch is visible, but the sample apps do not show a full translation.

The [Store screenshots](/guide/mobile-screenshots#locales) page covers the locale settings and the folder layout.

<SearchNextSteps />
