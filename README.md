# Clipload

A macOS menu bar app that downloads videos and HLS/DASH streams with [yt-dlp](https://github.com/yt-dlp/yt-dlp).

- Download window with a queue (1–6 at a time), progress, retry and history
- Quality picker for streams (lists the available resolutions before downloading)
- Watches the clipboard for video links (ask, auto-download, or off)
- `clipload://` links from the Stream Grabber Safari userscript

## Requirements

- macOS 14+ on Apple silicon, Xcode installed
- `brew install yt-dlp ffmpeg`

## Build

```bash
./build.sh
```

Then copy `Clipload.app` to `/Applications`.

## Stream Grabber userscript

`userscripts/stream-grabber.user.js` adds a ⬇ button to videos in Safari (via the Userscripts extension).
Replace `PASTE-YOUR-CLIPLOAD-TOKEN-HERE` with your token:

```bash
defaults read local.clipload token
```

Links without the right token still work but ask for confirmation first.

DRM-protected streams are not supported.
