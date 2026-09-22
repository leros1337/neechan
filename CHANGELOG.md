# Changelog

Notable changes per release. Earlier releases are listed under
[Releases](../../releases).

## 2.4.3

Any post can be reported, a saved thread reads properly with no network, and the
App Store build stops offering what it cannot give.

### Reporting

- **A post can be reported from its own menu.** Long-press a post, or a thread
  in the catalog, and the menu now offers Report. On 2ch the report goes
  straight to the moderators through the site's own endpoint -- a comment, no
  captcha. On 4chan working correctly via opening web page and solving captcha.
- **The agreement says so.** The first-launch terms gained a Reporting &
  Blocking section, which had been left out for as long as there was nothing to
  promise.

### Offline

- **A 4chan thread can be saved for offline reading.** The menu item was
  missing on 4chan, and deliberately: the archiver kept the server's own bytes
  and read every saved file back as 2ch's shape, so a saved 4chan thread would
  have been a file nothing could open. It now reads each one the way the site
  that wrote it writes threads -- which the saved row had recorded all along,
  since the schema gained a site column. Threads saved before this are
  unaffected and need no migration.
- **A saved thread's pictures come off the device.** The thumbnails and files
  were being downloaded and then never read: a saved thread still asked the
  site for every one of them, so "offline" meant the text and nothing else, and
  the bytes on disk were dead weight. A thread read from the device now points
  at its own copies. Save with thumbnails only and the full picture is still
  fetched if you open it, which is what that choice means.
- **Saving says what it is doing.** Keeping a thread with all its files can run
  to hundreds of megabytes, and it used to happen in complete silence: the
  archiver counted its progress and the caller threw every value away. A
  capsule at the foot of the thread now counts the files as they land, and can
  be cancelled -- the thread's text is written before any file is fetched, so
  stopping halfway leaves a thread that still reads, with some pictures
  missing.

### Boards

- **The App Store build lists 2ch's Творчество section.** Its 2ch directory
  carried four boards -- Аниме, Манга, Фэндомы, Визуальные новеллы -- which is
  a thin thing to hand a reader. Дизайн, Столовая, Хобби, Музыканты,
  Фотография, Живопись and Работа и карьера join them, read off the site's own
  directory and checked one by one against the age gate: a board that is listed
  and then refuses to open reads as a broken app rather than as a restriction.
  /wp/ Обои is left out, because a wallpaper board is an image dump with no
  subject holding it together; /izd/ Графомания is left out because 2ch files
  it under reader-made boards, which are gated wholesale.

### Restrictions

- **Links leave the app until you say you are 18.** A link off the imageboard
  opened in a browser sheet inside the app. That sheet is a surface the app
  answers for, and it will follow wherever a link a stranger wrote goes -- so
  until the age gate is answered, links now go to Safari instead, where the
  system's own web restrictions apply. Afterwards the existing preference
  decides, as before. The switch in General is disabled while the gate is shut
  rather than quietly doing nothing, and says where links go and how to change
  it. Nothing moves in the ordinary build, which starts with the gate open.

### Settings

- **The App Store build drops three more settings it cannot act on.** The
  Uploads section in Media -- make files unique, remove metadata, random file
  names -- is about a file on its way to a post, and that build attaches
  nothing. "Add to favorites when I reply" cannot fire there either. And the
  watcher's "Replies to me" notification mode wants posts of the reader's own
  for a reply to arrive at, so it is left out of the picker; a stored value
  naming it now reads as Off, which matters because it was the default. The
  watcher itself stays: it checks favourited threads for new posts, which is
  reading, and it works the same in both builds.
- **The passcode screen is gone from the App Store build.** A passcode is
  bought on the site and spent on posting -- it skips the captcha and raises the
  file limit -- and that build cannot post, so the screen pointed at a purchase
  it had nothing to do with. Cookies, which is where a passcode already granted
  is cleared, is untouched.
- **The App Store build stops counting posts it cannot send.** Statistics
  listed "Posts sent" beside the reading figures, where it could only ever read
  zero. Time in the app and threads opened still mean something and stay.
- **The Default board field suggests `a`, not `b`.** The example named a board
  the App Store build does not list, and one the age gate turns away on 2ch.

### Fitting in

- **Thumbnails start at full size.** They opened at 80%, on the reasoning that
  the site's thumbnails are bigger than a post needs -- but a thumbnail shown
  smaller than it was served is a picture you have to open to see. Scaling them
  down is still a slider away.
- **The system prompts speak German.** The app claims English, Russian and
  German, but only carried `InfoPlist.strings` for the first two, so a German
  reader was asked for Face ID -- and for permission to write to their photo
  library -- in English. A missing translation of these is invisible: iOS falls
  back to the development language without saying anything, which is why it went
  unnoticed. A test now reads the languages the app declares and fails if any of
  them is missing a prompt, or is still carrying the English sentence.

### Building

- **The app has its shipping identity.** The submitted build is
  `pro.neechan.app`, named **Neechan**; the unrestricted build sideloaded from
  Releases is `pro.neechan.app-dev`, named **Neechan X**, so the two sit on a
  device together instead of replacing one another. These are no longer
  placeholders to be swapped by hand at submission time -- there is nothing left
  to remember, and `make check-appstore` and `make ipa-appstore` both fail if
  the identifier or the name under the icon drifts from what ships. The
  identifier is permanent once the app is published.
- **Everything else the app names itself by moved with it.** The os_log
  subsystem, the watcher's background-task identifier and the reachability
  queue label were all still `com.lain.neechan`, from before the app had a
  name. They are now under `pro.neechan.app`. If you follow the logs, the
  predicate is `subsystem == "pro.neechan.app"`. The user-agent logger had its
  own copy of the subsystem string rather than a reference to the shared one,
  which is how the two would eventually have disagreed; it now reads the shared
  one. A test holds the background-task identifier and the `Info.plist` entry
  that permits it together, because the scheduler raises rather than returns
  when they disagree -- a drift there is a crash on launch, and the two halves
  are not even edited in the same file.

### Privacy

- **The app carries a privacy manifest.** `PrivacyInfo.xcprivacy` declares the
  two required-reason API categories the binary actually reaches -- file
  timestamps, for the media cache and saved threads, and user defaults, for
  preferences -- and records that the app tracks nobody and collects nothing.
  Without it App Store Connect refuses the upload outright.

## 2.4.2

A long press on a video offers what a long press on a picture always has.

### Gallery

- **The long-press menu works on a clip.** Pressing and holding a picture in
  the viewer offers the post it came from, saving, sharing and the link
  actions; pressing and holding a video did nothing at all. The menu was left
  off on purpose: for the press-and-hold animation the system holds a second
  copy of whatever the menu is attached to, and a copy of the page was a copy
  of the player -- it opened the file again and took the picture with it, so
  the clip played twice over itself and the copies piled up as you swiped. The
  menu now hangs on a pane of glass over the page rather than on the page, and
  a copy of an empty rectangle costs nothing.

### Under the hood

- **A build that succeeded no longer fails.** `xcodebuild -quiet` swallows a
  compiler's warnings and then reports the task that printed them as a command
  that failed, which stopped the App Store build being installed although it
  had built. The build is read by xcbeautify instead, builds only the
  architecture the simulator actually runs -- it was compiling x86_64 as well,
  for a machine that has none -- and the warnings it was complaining about are
  fixed rather than hidden.

## 2.4.1

Video that stopped a second or two in and never came back. The viewer fetches
the whole clip while it plays now, shows how much of it has arrived, and a
player that does stall starts itself again instead of sitting on a spinner.

### Media

- **A clip is fetched whole while you watch it.** The player read a few
  megabytes ahead of where it had got to, which is not enough for a clip whose
  bitrate is higher than the connection can carry: a 5800 kbps video wants
  722 KB/s sustained, and a connection that manages less runs out however far
  ahead the player looks. The rest of the file is now pulled in the background
  while the opening plays. The pieces land where playback already reads from,
  so nothing waits for a download to finish -- the picture still starts on the
  first frames, and the reads behind it come off the disk instead of the
  network.
- **The scrubber shows how much has arrived**, as a dimmed bar behind the
  playhead. It counts from the start of the file to the first piece missing,
  so it never promises more than can actually be watched through.
- **A clip that stopped no longer stops for good.** When playback ran out the
  clock stopped, and with the clock stopped the display layer never handed its
  pictures back, so it never had room for more, so the amount of video ahead of
  the clock never grew, so the clock never started again. Everything needed to
  carry on was already in hand and the clip waited for ever anyway. It now
  notices, gives up what the renderer is holding, and starts again from the
  picture that is actually next.
- **A clip whose sound never finished now ends.** Everything that decides a
  clip is over waited for the picture and the sound both to run out, and a seek
  landing on the end of the file could leave the sound's half never saying so.
  The clip then sat at its last frame, and pressing play ran the clock on over
  a frozen picture, counting up past the end of the file. A clip with a picture
  is over when the picture is, and playing one that has run out starts it from
  the beginning.
- **Sound survives a seek.** Sound arriving after a seek was held to the same
  test a picture is: at or after where you asked, and no more than five seconds
  past it. That upper bound belongs to pictures, which have to pick out the one
  frame the seek was waiting for; sound only has to stop being the old
  position's. When the first run past the target overshot the window -- a
  sparse file, or a seek close to the end -- nothing ever matched it, and every
  run for the rest of the clip was dropped, so the clip played silent until
  another seek happened to land better.

## 2.4.0

Video is played by the app's own player now, built on a trimmed FFmpeg 9 with the
device's hardware decoders underneath, and with that the last GPL component is gone:
Neechan is MIT. Also in here: full-size images on 4chan open again.

### Media

- **WebM is decoded by the graphics hardware where the device has a VP9
  decoder.** It was always decoded in software, because asking for hardware on
  a device without a VP9 decoder leaves the clip sitting there rather than
  reporting a failure. The app now asks VideoToolbox what this device has and
  follows the answer, which on an iPhone 12 or newer, and on Apple silicon,
  means a long clip no longer costs a full CPU core and a warm phone. Devices
  without the decoder are unchanged.
- **`.mkv` files play.** They were already recognised and sent to the same
  decoder a WebM goes to, but a Matroska file is the one container that can
  hold anything, and the codecs it usually holds outside a WebM -- H.264, HEVC,
  AV1, FLAC, AC-3, DTS -- are now all decoded rather than opening to nothing.
- **The player is the app's own.** Video used to go through KSPlayer, which
  brought a second media stack with it and decided things like the engine and
  autoplay in global state that a gallery kept fighting. Playback is now built
  directly on FFmpeg and the system's own render synchronizer: the same clock
  drives picture and sound, a clip that loops never blanks between repeats, and
  muting a clip before it has opened is remembered instead of dropped.
- **The gallery reads ahead.** A clip's next few megabytes are fetched while it
  plays rather than one piece at a time on demand, and the next video in the
  thread is warmed while the current one runs, so a swipe lands on a picture
  rather than a spinner. Scrubbing lands where the finger let go, a clip stops
  at its end and stays stopped, and swiping away from a video stops it: one
  player serves every page, so two clips can no longer play over each other.
- **Saving an MP4 to Photos works.** It reported success and saved nothing, and
  an attempt to check what had landed crashed the app on devices without full
  library access. The save is add-only now and asks for nothing more.

### Fixed

- **Full-size images on 4chan open.** Every one of them was refused with a 403
  while its thumbnail loaded fine. The gallery named the 2ch mirror as the page
  the file was linked from, whichever site the file was on, and 4chan's media
  host serves a thumbnail to anyone but not a full file linked from elsewhere.
  Every request for a file now names the file's own site. A refusal is also
  written to the log with the headers that earned it, instead of surfacing as
  "not an image".

### Licensing

- **Neechan is MIT now**, not GPL-3.0. The GPL came from the FFmpeg
  distribution the app used, which was built with `--enable-gpl` for a Samba
  client nothing here ever called, and from KSPlayer. Both are gone. FFmpeg is
  now this project's own build, trimmed to what an imageboard serves and
  configured without a single GPL component, and it is used under the LGPL.

### Under the hood

- **The FFmpeg build is a fortieth of the size.** The vendored one was 1.3 GB
  of libraries the app never linked: an SMB client, a Vulkan shader compiler,
  a second player. What replaces it is 57 MB and contains the containers and
  codecs the app actually opens, and nothing else.

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
