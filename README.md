# Neechan

[![Release](https://github.com/leros1337/neechan/actions/workflows/release.yml/badge.svg)](https://github.com/leros1337/neechan/actions/workflows/release.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

**English** · [Русский](README.ru.md)

A native iOS client for the imageboards **2ch** (`2ch.org` / `2ch.life`) and
**4chan**, written in Swift 6 and SwiftUI for iOS 26. It aims for feature parity with
the Android client [DashchanFork](https://github.com/TrixiEther/DashchanFork) on 2ch,
and uses Apple's Liquid Glass design system for the navigation layer.

Unofficial and unaffiliated with either site.

<img src="preview.png" alt="The board list, in the app's dark theme" width="320">

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
- **Posting** — on 2ch: replies and new threads, the markup toolbar wrapping what you
  select, drafts, attachments with metadata stripped and randomised names, and the
  emoji captcha with its proof-of-work. 4chan is read-only: its posting host sits behind
  a browser-only check that refuses the app's own requests, so the reply button is not
  offered there rather than offered and refused.
- **Media** — a gallery with zoom and a full-screen viewer; WebM plays through FFmpeg,
  and a WebM you save is converted to H.264 MP4, because Photos will not accept one.
- **Keeping up** — favourites with a watcher and unread counts, notifications, history,
  threads saved for offline reading, and the board archive.
- **Filtering** — autohide rules with a live regex tester, hidden threads collapsed to a
  line, hidden posts, and per-thread rules.
- **Fitting in** — themes including imported Dashchan JSON ones, text and thumbnail
  scaling, an iPad split view, and Russian and English throughout.

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
drive the app against the live site, so they need a network and they will fail when 2ch
is having a bad day; `make test-packages` is the offline half.

First build is slow: FFmpegKit's prebuilt xcframeworks are several gigabytes. They are
cached in `~/Library/Caches/org.swift.swiftpm-neechan` and shared between the packages
and the app, so it only happens once.

`Neechan.xcodeproj` is generated and not committed. Edit `project.yml` instead and
re-run `make gen`.

## Releases

Pushing a version tag builds and publishes one:

```sh
git tag v0.2.0 && git push origin v0.2.0
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
| `Tools/record-fixtures.sh` | Re-records the fixtures from the live site |

`Packages/NeechanCore/Sources/NeechanCore/Engine` holds pure, synchronous value logic
with no SwiftData or networking imports. That is where most of the test suite lives.

## Licensing

Neechan is distributed under the **GPL-3.0** (see `LICENSE`). This is not optional: the
FFmpeg build vendored by FFmpegKit is configured with `--enable-gpl`, so anything
linking it inherits those terms.
