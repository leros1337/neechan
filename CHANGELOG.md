# Changelog

Notable changes per release. Earlier releases are listed under
[Releases](../../releases).

## 2.3.0

Threads read as threads. The posts in one run together as a single list instead
of a column of separate panels, and the board list stops drawing a line through
a gap that was already there.

### Threads

- **A thread is one list now.** Every post sat on a rounded card of its own,
  which read as a stack of windows rather than a conversation. Posts run
  together, divided by a hairline, the way imageboard clients have always shown
  them.
- **Cards are still there if you preferred them.** Settings -> Appearance ->
  Post layout chooses between the two, and the list is the default.
- **Your own posts keep their mark.** The border that traced a card becomes a
  bar down the leading edge, in two weights: one for a post you wrote, a lighter
  one for a reply to it -- which had nothing else marking it at all.
- **Posts you have not read keep their tint**, now a band across the full width
  rather than a tinted card.
- **The replies window still shows cards.** It lifts a handful of posts out of
  the thread they came from, where being separate is the point.

### Boards

- **No line between thread cards.** In the Cards layout a thread already sits on
  a panel of its own, so the divider drew a boundary the card had drawn already.
  The compact List layout keeps its dividers, which are the only thing between
  one row and the next.

## 2.2.0

Quieter threads: a post's files take one line instead of a row, a post you hide
actually goes, and the age gate stops making boards disappear.

### Threads

- **A post's files are one thumbnail now**, marked with how many there are, and
  tapping it opens the gallery exactly where it used to. They were laid out as a
  strip you scrolled sideways, which read as several posts' worth of media and
  cost a row of height on every post carrying more than one. Paging works as
  before: through the whole thread from inside one, through the opening post's
  files from the catalog.
- **Hiding a post hides it.** Until now the rule was stored and everything
  downstream of it agreed, but the post itself went on drawing in full -- so the
  app looked like it had understood and then ignored you.
- **A hidden post leaves the replies window**, and the reply count that opens it
  no longer counts what it will not show.
- **A `>>N` pointing at a post you hid is struck through**, so you can see
  without opening anything that a reply answers something you chose not to read.
  Still tappable: hiding is your own doing and you are allowed to look again.

### Restrictions

- **The age gate is 18+, and it no longer hides anything.** A board meant for
  adults stays in the list and refuses to open until the gate is on, and the
  refusal offers the way through instead of leaving you to find the setting. Its
  threads still keep out of Favorites, History and Saved threads meanwhile, and
  nothing is deleted.
- **Posting is no longer a switch.** It was a preference that could be turned
  off; it is simply on.

### Elsewhere

- **A fresh install opens on 4chan.** Anyone who has already chosen a site keeps
  their choice.
- **The two alternate icons swapped places.** If you were using one of them,
  Settings -> Appearance is worth a look: your home screen may be showing the
  other.

## 2.1.0

iPhone Duo is the headline, and the rest is what landed alongside it: two ways
to mark which posts are yours, a quieter gallery viewer, a new default look, and
a third mirror.

### iPhone Duo

The device has two displays and a hinge. The app already adapted to whatever
width it was given, so most of this is meeting the platform where it genuinely
differs.

- **Both displays, and the poses between them.** The outer display gets the tab
  shell and the inner one the sidebar, and what you were reading carries across
  as the device opens and closes.
- **Controls on the side.** The system stacks the toolbar and the tab bar down
  the edge of the outer display. The tab bar's mirroring -- which exists to put
  the minimized pill under your thumb -- is switched off there, because it was
  pushing the bar to the edge opposite the camera and the status bar rather than
  joining them.
- **The fold.** The gallery and the doomscroll feed hand the file one plane of a
  part-folded display and its controls the other. Grids keep an even number of
  columns so no column of cells straddles the crease, and anything drawn edge to
  edge stays clear of the front camera.
- This part needs **iOS 27.1**, which is where the APIs it is built on arrive.
  Everything else in this release works wherever the app runs.

### Threads

- **Claim a post as your own**, from its menu, in the thread and in the replies
  window. Posting from this device was the only thing that ever recorded an own
  post, which left no way to claim one written from a browser or a second
  device, and no way back from a wrong claim. A claim drives everything the
  badge already drives: the (Me) mark, the border, and the (Y) on every `>>N`
  answering it.
- **A `>>N` that answers one of your posts is marked.** 2ch already marks a
  reference to the opening post this way, so the shape is familiar. Only
  same-thread references are marked: post numbers are board-wide, so a `>>N`
  into another thread can carry a number you own here and would otherwise claim
  a stranger's post as yours.

### Gallery

- **The file info moved to the top of the viewer.** The name, size and
  dimensions sat on the bottom edge above the scrubber and the transport, which
  on a video made three rows of chrome over the picture -- and the card was the
  one row you never interact with. It now sits in the empty middle of the top
  bar. The name truncates in the middle, so the extension survives.

### Appearance

- **Amber is the default theme.** The app used to open on the cool light-blue
  scheme; that look stays, at the end of the list, under the name **Midnight**
  it carried before it became the default. If you chose it explicitly you keep
  it -- a rename is not a reason to take somebody's choice away.
- **A third app icon**, a hand throwing a peace sign, called Peace. The three
  icons now sit side by side as one row rather than three full-width rows, and
  the one in use is ringed rather than ticked.

### Forum

- **2ch.su is offered as a mirror**, alongside the other two. Links from it
  already opened when pasted; now it can be read on.

### Fixed

- The replies pill was missing from a post opened as a quote popup, so whether a
  post had replies depended on how you had arrived at it.
- The 4chan slider captcha was requested up to four times instead of once. A
  bare `.none` against an optional retry policy is `Optional.none`, not
  `RetryPolicy.none`, so the request fell through to the client's default -- the
  opposite of the intent, since a puzzle does not improve by being asked for
  three times in a row.
- Toolbar buttons that were text alone now carry a symbol as well. Sixteen of
  them did, which the system will not place on a vertical axis at all.
- A post no longer runs the whole width of a wide window; it gets the same
  measure the quote popup has always had.

### Also

- Replies, the attachment grid and the favorites window open to the side on a
  display wide enough to hold them beside the thread.
- A build can start cautious, with posting fixed off, and Settings says so when
  it does.
- Every compiler warning in a clean build is gone.

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
