# Neechan

[![Release](https://github.com/leros1337/neechan/actions/workflows/release.yml/badge.svg)](https://github.com/leros1337/neechan/actions/workflows/release.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

**English** · [Русский](README.ru.md)

A native iOS client for the imageboards **2ch** (`2ch.org` / `2ch.life`) and
**4chan**, written in Swift 6 and SwiftUI for iOS 26, using Apple's Liquid Glass design
system for the navigation layer.

Unofficial and unaffiliated with either site.

<img src="preview-1.png" alt="A board's threads as cards, in the app's dark theme" width="320">
<img src="preview-2.png" alt="Every attachment in a thread, as a grid" width="320">

## Install

Download the `.ipa` from [Releases](../../releases).

The build is **unsigned**: there is no signing certificate in this repository and there
should not be one. It cannot be installed by tapping it — use
[AltStore](https://altstore.io), [Sideloadly](https://sideloadly.io), or your own Apple
developer account. iOS 26 or newer, iPhone or iPad.

## What it does

- **Reading** — boards as a catalog or page by page, in list, card or grid layout;
  threads with reply counts, quote popups, a replies window, in-thread search, and your
  place kept so a thread reopens where you left it.
- **Two imageboards** — a switch on the board list flips between 2ch and 4chan.
  Favourites, history, hidden threads and everything else you keep belong to the site
  they came from, and a pasted link opens on whichever site it names.
- **Posting** — replies and new threads, the markup toolbar wrapping what you select,
  drafts, attachments with metadata stripped and randomised names, and 2ch's emoji
  captcha with its proof-of-work. **Posting to 4chan does not currently work**: its
  posting host sits behind a script that computes a cookie in a browser, and the server
  refuses that cookie when the app replays it. The reply form is still offered rather
  than hidden, so the day that changes it is obvious; reading 4chan is unaffected.
- **Media** — a gallery with zoom and a full-screen viewer; WebM plays through FFmpeg,
  and a WebM you save is converted to H.264 MP4, because Photos will not accept one.
- **Doomscroll** — a thread's videos as a full-screen vertical feed: one clip per
  screen, autoplaying, looping and silent, with one sound control for the whole session
  and the next clip fetched ahead so a swipe does not land on black.
- **Keeping up** — favourites with a watcher and unread counts, notifications, history,
  threads saved for offline reading, and the board archive.
- **Filtering** — autohide rules with a live regex tester, hidden threads collapsed to a
  line, hidden posts, and per-thread rules.
- **Restrictions** — one screen that says what the app will show: NSFW mode, which
  blurs every thumbnail until you tap it, and an 18+ gate. Boards meant for adults stay
  in the directory with the gate shut — nothing goes missing — but they refuse to open,
  and the refusal offers the way through. Threads on them keep out of Favorites, History
  and Saved threads until you turn it on, and nothing is deleted.
- **Fitting in** — themes, including ones imported from a theme file, text and thumbnail
  scaling, an iPad split view, and English, Russian and German throughout.

## Build from source

Requirements:

- macOS 26 with Xcode 26.6 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

```sh
make gen            # regenerate Neechan.xcodeproj from project.yml
make test-packages  # fast: pure Swift package suites, no simulator
make sim            # build, install and launch on the iPhone simulator
make ipa            # unsigned .ipa in .build/, the same build CI publishes
```

`make test` additionally runs the simulator test bundles. Those include XCUITests that
drive the app against the live sites, so they need a network and they will fail when
2ch or 4chan is having a bad day; `make test-packages` is the offline half.

First build is slow: FFmpegKit's prebuilt xcframeworks are several gigabytes. They are
cached in `~/Library/Caches/org.swift.swiftpm-neechan` and shared between the packages
and the app, so it only happens once.

`Neechan.xcodeproj` is generated and not committed. Edit `project.yml` instead and
re-run `make gen`.

## Releases

Pushing a version tag builds and publishes one:

```sh
git tag v2.1.0 && git push origin v2.1.0
```

[`.github/workflows/release.yml`](.github/workflows/release.yml) runs the package tests,
builds the unsigned `.ipa` with `make ipa`, and attaches it to a GitHub Release. The
same workflow can be run by hand from the Actions tab, which leaves the build as a
workflow artifact instead of publishing it.

## Layout

| Path | What lives there |
| --- | --- |
| `Neechan/` | The app target: entry point, `Info.plist`, asset catalog |
| `Packages/NeechanAPI` | HTTP client for both sites, per-site adapters, models, comment HTML parser, captcha, posting. Foundation only |
| `Packages/NeechanSettings` | User preferences backed by `UserDefaults` |
| `Packages/NeechanCore` | Domain engine (pure logic), SwiftData store, service actors |
| `Packages/NeechanMedia` | Image and video playback, and the WebM converter. The only module allowed to import KSPlayer and FFmpeg |
| `Packages/NeechanUI` | SwiftUI screens, the Liquid Glass components, string catalog |
| `Packages/NeechanTestSupport` | Recorded API fixtures and their loader |
| `Tests/NeechanUITests` | XCUITests that drive the app against the live site |
| `Tools/record-fixtures.sh` | Re-records the 2ch fixtures from the live site |
| `Tools/record-4chan-fixtures.sh` | The same for 4chan |

`Packages/NeechanCore/Sources/NeechanCore/Engine` holds pure, synchronous value logic
with no SwiftData or networking imports. That is where most of the test suite lives.

## Licensing

Neechan is distributed under the **GPL-3.0** (see `LICENSE`). This is not optional: the
FFmpeg build vendored by FFmpegKit is configured with `--enable-gpl`, so anything
linking it inherits those terms.
