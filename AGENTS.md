# AGENTS.md

Guide for AI coding agents (and humans) working on **Close from Exposé**: a macOS menu-bar app
that adds close buttons to window thumbnails in Mission Control.

## Layout

| Path | What |
|---|---|
| `Sources/main.swift` | The whole app (single file, AppKit, no Xcode project). |
| `build.sh` | Compiles a universal `build/CloseFromExpose.app` with `swiftc`, writes `Info.plist`, signs. `./build.sh install` also copies to `/Applications` and relaunches. `VERSION=x.y.z` sets the bundle version. |
| `scripts/create-signing-cert.sh` | One-time local self-signed code-signing identity, so rebuilds keep the Accessibility grant. |
| `scripts/make-dmg.sh` | Packages `build/CloseFromExpose.app` into `build/CloseFromExpose.dmg` (drag-to-Applications layout). |
| `scripts/make-icon.swift` | Draws the icon → `Resources/AppIcon.icns` + `Resources/AppIcon.png`. |
| `.github/workflows/build.yml` | Builds on every push/PR; on a `v*` tag publishes a GitHub release with `CloseFromExpose.dmg`, `CloseFromExpose.zip` and `SHA256SUMS`. |

There are no tests and no dependencies. Verify by building and using Mission Control.

## How it works

`main.swift` sections, in order:

1. **AX helpers**: thin wrappers over `AXUIElementCopyAttributeValue`. AX coordinates are
   top-left origin; `toCocoa()` converts to AppKit's bottom-left origin.
2. **Logging**: appends to `~/Library/Logs/CloseFromExpose.log`.
3. **Mission Control model**
   - `Config`: detection rules loaded from
     `~/Library/Application Support/CloseFromExpose/config.json` (written with defaults on first
     run, re-read each time Mission Control opens). They exist so detection can be retuned
     **without rebuilding**: a rebuild with an ad-hoc signature loses the Accessibility grant.
     When adding fields, remember a decode failure silently falls back to defaults and
     **overwrites** the user's file.
   - `MissionControl.isOpen()`: on macOS 27 Mission Control is drawn by
     `com.apple.WindowManager`, and while it's open there's an on-screen `WindowManager` window at
     **layer 19** (`CGWindowListCopyWindowInfo`, no permission needed). Fallback for older
     macOS: the Dock's AX tree gets a child with identifier `mc`.
   - `thumbnails()`: walks the AX tree of the processes in `config.processes`. On macOS 27:
     ```
     AXApplication (WindowManager)
       AXGroup id=mc.display                    (full screen)
         AXButton id=<bundle id>.space.<n>       one per thumbnail
                  title/desc = window title (may be empty, e.g. PDFgear)
                  wid = CGWindowID of the real window   ← key attribute
         AXGroup id=mc.spaces                    Spaces bar (excluded)
     ```
     The bundle id is parsed from the identifier, the window id from `wid`.
   - `sanitize()`: windows assigned to several desktops appear only under *another* Space's
     identifier, twice, with that Space's frame. Thumbnails of the current Space (private
     `CGSCopyManagedDisplaySpaces`) are kept once per `wid`; the others are rebuilt by
     `relocate()` from the WindowManager "App Icon Window"s (layer 17, centred on each thumbnail's
     bottom edge, +41 pt), sized as real window × the shared thumbnail scale, matched by
     closeness to their old layout.
4. **Window lookup & closing**: `match()` resolves a thumbnail to a real AX window. With `wid`,
   it gets the owner PID from `CGWindowListCopyWindowInfo` and compares each AX window via the
   private `_AXUIElementGetWindow`, which is stable and used by yabai and AltTab. Without `wid`,
   `guessWindow()` matches by app, then title, then aspect ratio, and refuses ambiguous matches.
   Closing presses the window's `AXCloseButton`.
5. **Close button overlay**: `CloseButtonPanel` is a borderless, non-activating `NSPanel` at
   `assistiveTechHighWindow` level with `.stationary` collection behaviour, which keeps it above
   Mission Control. A click doesn't activate the app or dismiss Mission Control. The view draws
   a round ✕, or a "✕ title" pill when `label` is set.
6. **Controller**: polls `isOpen()` every 0.25 s. While open, it ticks at 30 Hz: it re-reads
   thumbnails, which animate and reflow, and lays out buttons for the thumbnail under the mouse
   only. Panels are keyed by window id (`panels: [String: CloseButtonPanel]`), so a button never
   jumps between windows.
   - **Stacked groups**: same bundle id with frames overlapping more than 30%. On hover, Mission
     Control fans the stack out, but **the AX frames don't change and no attribute marks the
     highlighted window**. Corner buttons would land in the wrong places, so a group gets a
     fixed column of pills above it, or below if there's no room. The hover area is the union
     plus 25% and the pills.
   - Lone windows get a corner ✕, on the first corner not covered by another thumbnail.
   - Buttons are hidden for the first 0.35 s while Mission Control animates in.
7. **App**: menu-bar item (`LSUIElement`), Accessibility prompt plus a wait loop, and the login
   item via `SMAppService.mainApp`. It is enabled on first run only; after that the menu toggle
   decides (`UserDefaults` key `loginItemConfigured`).

## Working on it

- **Accessibility permission**: TCC ties it to the code signature. Ad-hoc builds lose it on
  every rebuild, and the user has to remove the app from the list and add it again. Use
  `scripts/create-signing-cert.sh` locally. The designated requirement then becomes
  `identifier "com.santiago.CloseFromExpose" and certificate leaf = H"..."`, which survives
  rebuilds. **Don't change the bundle identifier** without a reason: that also resets the grant.
- On macOS 27 the setting is under **Privacy & Security → Device Control and Data Access**.
  Deep link: `open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"`.
- A terminal or agent shell usually has **no** Accessibility permission, so it can't read
  Mission Control's AX tree itself. Investigate through the app: set `"dump": true` in
  `config.json`, open Mission Control, and read the log. `open -a "Mission Control"` toggles it
  from a shell. Listing windows with `CGWindowListCopyWindowInfo` works without permission.
- Edit, run `./build.sh install`, open Mission Control and check the log.
- The login item points to `/Applications/CloseFromExpose.app`, so test there, not in `build/`.

## Releasing

Push a tag: `git tag v1.2.3 && git push origin v1.2.3`. CI builds a universal binary, signs it
ad-hoc (not notarized), packages a `.dmg` (`scripts/make-dmg.sh`) and a `.zip` (`ditto`), and
creates the GitHub release with notes and `SHA256SUMS`. The README's download button links to
`releases/latest/download/CloseFromExpose.dmg`, so keep that asset name stable.

## Known limitations / ideas

- Grouped windows can't get per-window corner buttons; see Controller above.
- Hover hit-testing on overlapping lone thumbnails assumes the last AX child is on top.
- Not notarized. Notarization needs a paid Developer ID.
- The Dock fallback for pre-27 macOS is untested.
