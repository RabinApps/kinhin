# Forge icons

One single-color SVG per forge, named after `ForgeID.rawValue` and loaded as a
template image by `ForgeIcon` (`Sources/kinhin-app/UI/SwiftUI/ForgeIcon.swift`).
`NSImage` renders SVG natively, so the files are used exactly as published.

Source: [Simple Icons](https://simpleicons.org) v16.33.0 (CC0 1.0), unmodified
(`https://cdn.jsdelivr.net/npm/simple-icons@16.33.0/icons/<slug>.svg`). Every
file is named after its Simple Icons slug.

The marks are trademarks of their respective owners and are used only to
identify each service. Adding a forge means adding its SVG here; `ForgeIconTests`
fails for any `ForgeID` without one.
