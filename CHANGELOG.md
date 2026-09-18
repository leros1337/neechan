# Changelog

Notable changes per release. Earlier releases are listed under
[Releases](../../releases).

## 2.1.0

Support for iPhone Duo, which has two displays and a hinge. The app already
adapted to whatever width it was given, so most of this is meeting the platform
where it genuinely differs: controls the system moves to the side, a display
that divides down the middle while the device is part-folded, and a front
camera in the corner it used to draw into.

### iPhone Duo

- **Both displays, and the poses between them.** The outer display gets the tab
  shell and the inner one the sidebar, which is the split the guidance asks for,
  and what you were reading carries across as the device opens and closes.
- **Controls on the side.** The system stacks the toolbar and the tab bar down
  the edge of the outer display. The tab bar's mirroring -- which exists to put
  the minimized pill under your thumb -- is switched off there, because it was
  pushing the bar to the edge opposite the camera and the status bar rather
  than joining them.
- **The fold.** The gallery and the doomscroll feed hand the file one plane of a
  part-folded display and its controls the other. Grids keep an even number of
  columns so that no column of cells straddles the crease, and anything drawn
  edge to edge stays clear of the front camera.
- This part needs iOS 27.1, which is where the APIs it is built on arrive.
  Everything below applies wherever the app runs.

### Everywhere

- **Toolbar buttons carry a symbol as well as a title.** Sixteen of them were
  text alone, which the system will not place on a vertical axis at all.
- **A measure for thread posts.** A post no longer runs the whole width of a
  wide window -- the same clamp the quote popup has always had.
- **Replies, the attachment grid and the favorites window open to the side** on
  a display wide enough to hold them beside the thread.

## 2.0.0

The major number moves because Neechan is no longer a client for one imageboard,
and because everything it had already saved for you had to be rewritten to say
which one it came from.

### 4chan

- **A second imageboard.** A switch on the board list flips between 2ch and
  4chan: boards, catalog, threads, archive, media and quote links all work the
  same way on both.
- **Your data knows where it came from.** Favourites, history, saved threads,
  drafts, own posts, hidden threads and pinned boards belong to the site they
  were made on, and only that site's are shown. Everything stored before this
  release is kept and attributed to 2ch.
- **Pasted links open on the site that wrote them**, whichever site you happen
  to be reading.
- **Posting to 4chan does not work.** Its posting host sits behind a script that
  computes a cookie inside a browser, and the server refuses that cookie when
  the app replays it. The reply form is offered anyway rather than hidden, so it
  is obvious the day that changes. Reading 4chan is unaffected.

### Doomscroll

A thread's videos as a full-screen vertical feed, from the thread's own menu:
one clip per screen, autoplaying, looping and silent, with a single sound
control that covers every clip. Scrolling stops the clip you left and starts the
one you arrived at, and the next clip's opening seconds are fetched while the
current one plays, so a swipe does not land on black.

### Restrictions

A new Settings screen that says what the app will and will not show:

- **NSFW mode** — off by default, which blurs every thumbnail until it is
  tapped. This replaces the old Safe for work switch in Appearance, and your
  existing choice is carried across.
- **Mature 21+** — on by default. Turning it off hides boards meant for adults
  and makes them unreachable: not only from the directory, but from the go-to
  field, a pasted link, a favourite, the board the app opens on, and a
  cross-board quote. Threads on them leave Favourites, History and Saved threads
  while it is off. Nothing is deleted, and it all returns when you turn it back
  on. Turning it back on asks how old you are.
- **Posting enabled** — on by default; off removes every way to write, on both
  sites.

### German

The whole interface is now available in German alongside English and Russian —
every string, including the ones that count things. A site's own board names and
post text stay in the language they were written in.

### Fixed

- Saving a video reported no progress at all when it had already been watched,
  which is most of the time: the pieces left on disk were filled in silently and
  the capsule sat at nothing until it was suddenly done.
- `ForumSettingsView` could never say "No board with that code", because the
  optional it checked was flattened away.

### Also

- A new default app icon.
- The reply form, the markup toolbar and the captcha follow whichever site you
  are on.
