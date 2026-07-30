# SomaBar

A macOS menu bar app for listening to [SomaFM](https://somafm.com) internet radio.

SomaBar lives in the menu bar: pick any of SomaFM's ~46 channels, see what's playing at a glance, and control playback without switching apps. Built entirely in Swift — no Electron, no web views. It is a port of [DIBar](https://github.com/drmikexo2/DIBar-macOS) (a di.fm menu bar player) to SomaFM.

## Features

- **All SomaFM channels** with instant search, favorites, and a recently-played list
- **Now playing in the menu bar** — artist and song rendered right in the status item, with a play-state glyph (each component can be toggled off)
- **Four stream qualities** — MP3 highest (up to 320k), AAC 128k, AAC+ 64k, AAC+ 32k
- **Self-healing playback** — automatic failover across SomaFM's redundant stream servers, reconnect with backoff, and recovery after sleep or network loss
- **Global hotkeys** (⌃⌥⌘ P / ← / →) and media-key support with macOS Now Playing integration
- **Track-change and channel-switch notifications** with channel artwork
- **Listening history** — local SQLite log with daily/all-time totals, liked/disliked songs, and a stats.fm-compatible `endsong.json` export
- **Last.fm scrobbling** (also feeds Airbuds) with an offline queue
- **Local song ratings** — thumbs up/down, kept on your Mac (SomaFM has no accounts)
- **Sleep timer**, output-device picker with AirPlay, launch at login, Sparkle auto-updates

## Support SomaFM

SomaFM is commercial-free and 100% listener-supported. If you listen through SomaBar, please [support SomaFM directly](https://somafm.com/support/).

## A note on the SomaFM API

SomaFM no longer offers a public third-party API. SomaBar uses their openly reachable endpoints (`channels.json`, the published `.pls` playlists, and the per-channel song feeds) as a polite guest:

- every request carries an identifying `User-Agent`
- the channel list and song feeds are fetched conditionally and infrequently — the ICY stream metadata the player already receives drives the now-playing display
- streams use SomaFM's official playlist URLs, never hardcoded server addresses

If SomaFM changes or restricts these endpoints, the app will need updating.

## Building

Requires macOS 14+ and Xcode 15+.

```sh
cp SomaBar/Services/Secrets.swift.example SomaBar/Services/Secrets.swift
# optional: paste your Last.fm API key/secret into Secrets.swift for scrobbling
xcodebuild -project SomaBar.xcodeproj -scheme SomaBar -destination 'platform=macOS' build
```

The app builds and runs fine with empty secrets — the Last.fm row in Settings simply shows that a key is required.

## Tests

```sh
xcodebuild -project SomaBar.xcodeproj -scheme SomaBar -destination 'platform=macOS' test
```

## Releasing

See [RELEASING.md](RELEASING.md).
