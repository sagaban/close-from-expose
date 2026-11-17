<p align="center">
  <img src="Resources/AppIcon.png" width="160" alt="Close from Exposé icon">
</p>

<h1 align="center">Close from Exposé</h1>

<p align="center">
  Close windows straight from macOS Mission Control.
</p>

---

macOS Mission Control (formerly Exposé) shows every open window, but gives you no way to close
one. **Close from Exposé** is a small menu-bar app that adds a close button to the thumbnails:

- **Single windows** — hover a thumbnail and a round **✕** appears on one of its corners
  (the first corner not covered by another thumbnail).
- **Stacked windows of the same app** (e.g. three Chrome windows grouped together) — hover the
  stack and a column of **✕ &lt;window title&gt;** labels appears just above it. Mission Control
  fans the stack out on hover without reporting the new positions, so per-window corner buttons
  can't follow it; the labels stay put instead.
- The button turns red on hover; click it and the real window is closed through its own close
  button, exactly as if you'd clicked the red traffic light (apps still get to ask "save changes?").

## Install

1. Download `CloseFromExpose.zip` from the
   [latest release](https://github.com/sagaban/close-from-expose/releases/latest) and unzip it.
2. Move **CloseFromExpose.app** to `/Applications`.
3. The app is not notarized, so macOS will block the first launch. Either run
   ```sh
   xattr -dr com.apple.quarantine /Applications/CloseFromExpose.app
   ```
   or try to open it once, then go to **System Settings → Privacy & Security** and click
   **Open Anyway**.
4. Grant the **Accessibility** permission when asked. On macOS 27 it lives in
   **System Settings → Privacy & Security → Device Control and Data Access**
   (older versions: **Privacy & Security → Accessibility**). The app starts working as soon as
   the permission is granted.

The app adds itself to your login items on first run. Toggle that from the menu-bar icon →
**Abrir al iniciar sesión** (or System Settings → General → Login Items).

> Each downloaded release has a different ad-hoc signature, so after updating you may need to
> remove the app from the Accessibility list and add it again.

## Requirements

- **macOS 27** (tested on 27.2). Mission Control is drawn by the `WindowManager` process there,
  and thumbnails expose the window ID, which is what the app relies on.
- Older macOS versions (where Mission Control lives in the Dock) have a fallback code path, but it
  is untested.
- Apple Silicon or Intel (universal binary).

## Build from source

Requires the Xcode command line tools (`xcode-select --install`).

```sh
./build.sh            # → build/CloseFromExpose.app
./build.sh install    # build, copy to /Applications and relaunch
```

macOS ties the Accessibility permission to the app's signature. Ad-hoc signatures change on every
build, which means re-granting the permission after each rebuild. To avoid that, create a local
signing identity once:

```sh
./scripts/create-signing-cert.sh
```

`build.sh` uses it automatically when present.

To regenerate the icon: `swift scripts/make-icon.swift`.

## Troubleshooting

- **Menu-bar icon → Abrir log** opens `~/Library/Logs/CloseFromExpose.log`.
- Detection rules live in `~/Library/Application Support/CloseFromExpose/config.json`, re-read
  every time Mission Control opens. Set `"dump": true` to log the full accessibility tree of
  Mission Control on each opening — useful when a new macOS version changes its structure.
- A grey **✕** with a beep means the window couldn't be found or closed; the log says which.

## How it works

See [AGENTS.md](AGENTS.md) for the architecture, the macOS internals it depends on and how to
debug them.

## License

[MIT](LICENSE)
