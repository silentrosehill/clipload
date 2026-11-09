# Clipload

A macOS menu bar app (and Windows tray app) that downloads videos and HLS/DASH streams with [yt-dlp](https://github.com/yt-dlp/yt-dlp).

- Download window with a queue (1–6 at a time), progress, retry and history
- Quality picker for streams (lists the available resolutions before downloading)
- Watches the clipboard for video links (ask, auto-download, or off)
- `clipload://` links from the Stream Grabber Safari userscript

## macOS

### Requirements

- macOS 14+ on Apple silicon, Xcode installed
- `brew install yt-dlp ffmpeg`

### Build

```bash
./build.sh
```

Then copy `Clipload.app` to `/Applications`.

## Windows

Download **Clipload-Setup.exe** from [Releases](../../releases) and run it. It installs for your user only (no admin needed),
bundles yt-dlp and ffmpeg, adds a Start menu shortcut, and can start Clipload when you sign in.
There's also a portable zip.

Clipload sits in the tray (click it to open the window; right-click for the menu). Same features as on the Mac:
queue, stream quality picker, clipboard watching, `clipload://` links, and history.

Windows may show a SmartScreen warning because the app isn't signed: click **More info → Run anyway**.

### Build it yourself

The Windows app is `windows/clipload.py` (Python + PySide6). GitHub Actions builds the installer on every push
(see `.github/workflows/windows.yml`); pushing a `v*` tag publishes a release. To run it from source:

```bash
pip install pyside6
python windows/clipload.py
```

with `yt-dlp` and `ffmpeg` on your PATH.

## Stream Grabber userscript

`userscripts/stream-grabber.user.js` adds a ⬇ button to videos in your browser: Safari with the Userscripts extension,
or Chrome/Edge/Firefox with Tampermonkey. Replace `PASTE-YOUR-CLIPLOAD-TOKEN-HERE` with your token:

- macOS: `defaults read local.clipload token`
- Windows: Clipload Settings → Stream Grabber → **Copy token**

Links without the right token still work but ask for confirmation first.

DRM-protected streams are not supported.
