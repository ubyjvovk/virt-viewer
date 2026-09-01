# Native macOS SPICE viewer — proof of concept

A standalone SPICE client for macOS with **no GTK anywhere**: spice-client-glib
for the protocol, AppKit/Core Animation for the window, and a keycodemapdb
scancode table for the keyboard.

Scope so far: **screen, keyboard, absolute and relative mouse, guest cursor
shape and two-way plain-text clipboard**, plus a connect window, a password
prompt and a reconnect/close dialog so the viewer can be launched and recovered
without a terminal. There is deliberately no file transfer, no USB
redirection, no audio, and no multi-display support; the clipboard is UTF-8
text only.

## Build

```
bash macos-native/build.sh
```

That is the whole build. It does not touch the project's meson build and
produces `macos-native/build/spice-viewer`.

### The .app bundle

```
bash macos-native/make-bundle.sh
```

builds `macos-native/build/SPICE Viewer.app` — a double-clickable, relocatable
bundle that carries every non-system dylib it needs, so it runs on a machine
with no Homebrew. It calls `build.sh` for you (`SKIP_BUILD=1` bundles the
binary that is already there), then:

- copies the dependency closure with `dylibbundler` into
  `Contents/Resources/lib`, rewriting every install name to
  `@executable_path/../Resources/lib/` and deduplicating the `LC_RPATH` that
  dylibbundler can add twice;
- refuses to finish if any bundled Mach-O still names a path outside the
  bundle (`otool -L` sweep);
- ad-hoc **codesigns every dylib after the last `install_name_tool` rewrite**,
  then the bundle. Getting that order wrong is not a link error: dyld kills
  the process on launch and macOS reports "the application quit unexpectedly".

`CFBundleExecutable` is the viewer binary itself. Unlike the GTK bundle there
is no launcher script and no module caches to relocate, because nothing here
is `dlopen()`ed.

**The name and the identifier are placeholders.** `APP_NAME` (`SPICE Viewer`),
`BUNDLE_ID` (`io.github.virt-viewer.spice-viewer`) and `APP_VERSION` are three
variables at the top of `make-bundle.sh`, pending a decision on what this
viewer is called. Changing `BUNDLE_ID` makes macOS treat the result as a
different application — LaunchServices registrations, the Accessibility grant
and `NSUserDefaults` are all keyed on it — so change it before shipping, not
after.

`LSMinimumSystemVersion` is not hand-picked: the script takes the highest
`LC_BUILD_VERSION` `minos` of any Mach-O in the bundle. The Homebrew libraries
inherit their builder's SDK, and claiming to run on an older macOS than they do
only buys a silent dyld abort instead of a LaunchServices refusal.

The bundle is signed ad hoc, not with a Developer ID, and it is not notarized:
Gatekeeper will still quarantine it if it arrives from a browser. Building it
locally, as above, is fine.

### Dependencies

All from Homebrew, all already required by the main macOS port:

| package | why |
| --- | --- |
| `spice-gtk` | provides `spice-client-glib-2.0` (the GTK part is unused) |
| `spice-protocol` | protocol headers |
| `glib` | pulled in by spice-client-glib |
| `pkgconf` | dependency discovery |
| `libxml2` | `PKG_CONFIG_PATH` entry that `build.sh` adds for you |

Nothing beyond the macOS SDK is needed for the UI side: Cocoa, QuartzCore,
IOSurface and ImageIO ship with the system.

## Run

```
macos-native/build/spice-viewer [spice://HOST:PORT]
```

`spice://HOST:PORT` above is a placeholder — the URI is read from `argv[1]`,
never from a compiled-in default.

Two launch modes:

- **With a URI**, the viewer connects to it immediately, exactly as it always
  has.
- **With no arguments**, it opens the connect window instead: a URI field
  pre-filled with the last URI connected to from that window, and a default
  Connect button (Return activates it). Connecting remembers the URI in
  `NSUserDefaults` under `VsmLastURI` and then proceeds down the same path as
  the argv case. Only the URI is remembered — never a password.

From the `.app` bundle there is a third way in: a `spice://` URL or a
double-clicked `.vv` file, both of which join the same path — see "URLs and
.vv files".

⌘Q quits from any state *except* while keyboard capture is claiming it, where
a **tap** of ⌘Q goes to the guest and **holding it for a second** quits — see
"Menus and keyboard capture" below. When it does quit, every key still held is
released on the guest, the session is disconnected and the GLib thread is
joined before the process exits. It works while a modal dialog is up too — see
below.

Capturing the chords macOS reserves for itself (⌘Space, ⌘Tab, ⌘\`, the
screenshot keys) needs a one-time **Accessibility** grant; without it the
viewer runs exactly as it does below, minus those chords. See "System
shortcuts and the Accessibility grant".

### Environment variables

| variable | effect |
| --- | --- |
| `VSM_TRACE=1` | log every scancode, damage rect, motion, button and scroll event, every cursor define/hide/reset, and every clipboard transition (direction and byte/character counts only — never contents) |
| `VSM_DUMP_DIR=<dir>` | `SIGUSR1` writes the current guest framebuffer to `<dir>/frame-N.png` |
| `VSM_SELFTEST=1` | two seconds after the first frame, replay a fixed benign input script (arrows, Escape, each modifier, absolute motion, left/right click, scroll) through the real responder methods |
| `VSM_CURSOR_SELFTEST=1` | two seconds after the first frame, drive a synthetic cursor script (two shapes with different hotspots, then hide, then reset) through the real cursor code path |
| `VSM_CURSOR_CHURN=N` | with `VSM_CURSOR_SELFTEST`, replace the cursor N times as fast as possible first, so `leaks(1)` can show there is no per-define leak |
| `VSM_SENDKEY_SELFTEST=1` | three seconds after the first frame, send one harmless chord (Shift+F11) through the same path as the Send Key menu, so the ordered-press/reverse-release behaviour is provable without firing Ctrl+Alt+Del at a live guest |
| `VSM_FORCE_RELATIVE=1` | ask the server for **server (relative) mouse mode** once, as soon as it announces a mode. Inert unless the value is exactly `1`; without it the server's own choice stands. It also adds *Request Absolute/Relative Mouse Mode* to the Input menu, so one session can be switched both ways |
| `VSM_GRAB_SELFTEST=1` | four seconds after the first frame, replay the whole relative-mouse gesture — the click that takes the grab, a paced run of hardware-delta motion events (including sub-pixel ones), a button and a scroll while grabbed, the ⌃⌥ release chord on both entry points, and a switch back to absolute mode. Only useful together with `VSM_FORCE_RELATIVE=1`; dumps the framebuffer before and after the motion run into `VSM_DUMP_DIR` |
| `VSM_NO_EVENT_TAP=1` | behave as though there were no Accessibility grant: never install the event tap. The only way to test the degraded path on a machine that *has* the grant, since a process cannot revoke its own TCC entry |
| `VSM_SELFTEST_QUIT=1` | with `VSM_SELFTEST`, terminate via the ⌘Q action four seconds later |
| `SPICE_DEBUG=1 G_MESSAGES_DEBUG=all` | spice-client-glib's own protocol tracing |

The dump and self-test hooks exist because a macOS machine whose login session
is locked cannot be screenshotted (`screencapture` returns the lock screen) or
typed into, and a viewer still has to be able to prove what it renders and what
it sends.

## How it works

### Threads

spice-client-glib is driven entirely from one dedicated thread that runs the
GLib **default** main context. That has to be the default context rather than a
private one: spice-gtk schedules its connect coroutine with `g_idle_add()`
(`spice-channel.c:2810`) and flushes its transmit queue with
`g_timeout_add_full()`, and both attach to the global default context no matter
what the thread-default is. With a private context the session creates its main
channel and then silently never connects. Nothing else in the process iterates
the default context, so the GLib thread owns it outright.

The AppKit main thread never calls a `spice_*` function and never blocks on the
GLib thread. Traffic crosses in both directions asynchronously:

- guest → UI: `dispatch_async(dispatch_get_main_queue(), …)`
- UI → guest: `g_main_context_invoke_full()` on the GLib context

### Rendering

`display-primary-create` hands over a CPU framebuffer in
`SPICE_SURFACE_FMT_32_xRGB`, which is byte-identical to IOSurface's `BGRA`
format on little-endian. So:

1. On primary-create, allocate one IOSurface of the guest's size.
2. On each `display-invalidate`, copy **only the damaged rows** out of the
   guest buffer into the IOSurface. This happens on the GLib thread, which is
   the thread that owns that buffer, so the copy never races the decoder.
3. Coalesce: at most one main-thread hop is in flight at a time, so a burst of
   fifty small damage rects costs one Core Animation transaction, not fifty.
4. On the main thread, rebind `layer.contents` to the IOSurface so CA re-reads
   it.

IOSurface was chosen over a Metal texture because the framebuffer already lives
in CPU memory: an IOSurface *is* the zero-extra-copy way to hand CPU pixels to
the compositor, and CA uploads it to the GPU itself. A Metal path would add a
staging buffer and a command encoder for no gain at this scope, and a
`CGImage`/`drawRect:` path would throw away the damage information by
recomposing the whole frame.

Sharpness: the window's content size is set to *guest pixels ÷
backingScaleFactor* and `layer.contentsScale` to `backingScaleFactor`, so on a
2× Retina panel one guest pixel is exactly one physical pixel and the
compositor resamples nothing at all. A 2560×1440 guest opens as a 1280×720-point
window. The window keeps the guest's aspect ratio when resized, and
`magnificationFilter` is nearest so scaling up stays crisp rather than blurry.

### Keyboard

`vsm-keymap.c` is generated verbatim from keycodemapdb — the same database qemu
and spice-gtk use — mapping `NSEvent.keyCode` to XT (AT set 1) scancodes:

```
keymap-gen code-map --lang=stdc --varname=osx_to_xtkbd \
           keymaps.csv osx xtkbd > vsm-keymap.c
```

Extended keys come out as `0x1xx`, which is exactly the encoding
`spice_make_scancode()` expects (it rewrites `0x14b` to `0xe04b` on the wire).
Do not hand-edit the table; regenerate it.

macOS never delivers `keyDown:`/`keyUp:` for modifier keys — it delivers one
`flagsChanged:` per physical transition. Press versus release is derived from
the *device-dependent* modifier bit for that specific key (`0x01` left control,
`0x02`/`0x04` left/right shift, …), because the public `NSEventModifierFlag*`
masks collapse both physical keys onto one bit and would misreport the second
one. Caps Lock latches rather than repeating, so it is sent as a full
press/release pair.

Every held key is released when the window resigns key, when the application
resigns active, and on quit — otherwise a guest is left with a stuck modifier.

### Menus and keyboard capture

The menu bar has three menus beyond the Apple one:

| menu | item | shortcut | effect |
| --- | --- | --- | --- |
| *app* | Quit | ⌘Q | quit (but see capture, below) |
| View | Actual Size | ⌘0 | resize the window to guest pixels ÷ `backingScaleFactor` — the size it is given on connect, one guest pixel per physical display pixel |
| View | Enter/Exit Full Screen | ctrl+⌘F | native macOS fullscreen; AppKit renames the item itself |
| Input | Capture Keyboard | — | toggle, **on by default**, checkmarked while on |
| Input | Capture System Shortcuts | — | the event-tap tier; checkmarked while the tap is capturing, titled "(needs Accessibility)" until the grant exists |
| Input | Send Key ▸ | — | Ctrl+Alt+Del, Ctrl+Alt+Backspace, PrintScreen, F11 |

Actual Size and every Send Key item are disabled while no session is
connected; Actual Size is also disabled in fullscreen, where the window size
belongs to the screen. AppKit adds its own "Show Tab Bar"/"Show All Tabs"
items to any menu titled *View*; they are inert here.

**Keyboard capture** decides who owns ⌘. It defaults to **on**, because the
guests this viewer is built for (Omarchy/Hyprland and friends) bind their
window manager on SUPER, and a client that keeps a handful of ⌘ chords for
itself makes those guests unusable. While capture is on *and* a session is
connected *and* the guest view is the key window's first responder,
`-[VsmView performKeyEquivalent:]` consumes **every** ⌘ chord and forwards it
to the guest as scancodes — ⌘Q, ⌘W, ⌘H, ⌘M and ⌘0 included. AppKit offers key
equivalents to the key window's view hierarchy before the main menu, so the
view wins; the ⌘ key itself has already reached the guest through
`flagsChanged:`, and only the other key of the chord needs the press/release
pair the view sends (a key equivalent never produces a matching `keyUp:`).
That is tier 1, the mechanism that needs no permissions; with the event tap of
"System shortcuts and the Accessibility grant" installed, the tap has taken
the same chord long before AppKit looks for a key equivalent, and these
responder methods stand down entirely.

The consequences, in order of how surprising they are:

- **⌘Q does not quit while capture is on.** A tap of it types SUPER+Q into the
  guest; holding it for a second quits the viewer. See "The ⌘Q rule" below.
- The app's own shortcuts (⌘0, ctrl+⌘F) work only while capture is **off** or
  no session is connected.
- **The menu bar is always reachable with the mouse**, in every state, and
  that is how you turn capture off — as is the ⌃⌥ escape chord.
- With capture off, the bare ⌘ press is not forwarded either, so using a Mac
  shortcut cannot trip whatever the guest binds on SUPER. Every other
  modifier (control, option, shift) always reaches the guest.
- System-owned chords — ⌘Space, ⌘Tab, ⌘\`, the screenshot keys — never reach an
  application through AppKit at all. Capturing *those* is the event tap's job,
  described next; without the Accessibility grant they stay with macOS and
  everything else here is unchanged.

### System shortcuts and the Accessibility grant

Keyboard capture has **two tiers**, and the Input menu shows both:

| tier | mechanism | needs | catches |
| --- | --- | --- | --- |
| 1. Capture Keyboard | `VsmView`'s responder methods | nothing | every key AppKit delivers to the app, ⌘-chords included |
| 2. Capture System Shortcuts | `CGEventTap` (`vsm-tap.m`) | one-time Accessibility grant | additionally ⌘Space, ⌘Tab, ⌘\`, the screenshot keys — everything macOS would otherwise swallow first |

Tier 2 is a **session-wide, head-inserted, active** event tap: it sees key
down, key up and flags-changed events before the window server turns them
into Spotlight or the app switcher, and returns `NULL` for the ones it takes.
It takes an event only while capture is on **and** the viewer window is key
**and** the app is active **and** a session is connected; in every other state
it returns the event untouched, so the rest of the machine behaves exactly as
if the viewer were not running. This is the same mechanism Parallels, VMware
Fusion and Screen Sharing use, and it needs the same grant they do.

**Single source of keystrokes.** While the tap is installed and capture is on,
it is the *only* sender: `VsmView`'s `keyDown:`/`keyUp:`/`flagsChanged:`/
`performKeyEquivalent:` all return immediately (`tapOwnsKeyboard`), so a chord
cannot be delivered twice. The moment the tap goes away — no grant, or the
menu item toggled off — the flag clears and tier 1 behaves exactly as it did
before the tap existed.

**Granting Accessibility.** On first launch the viewer asks macOS to show its
one-time dialog (once per run — never a prompt loop). To grant it by hand:

1. **System Settings → Privacy & Security → Accessibility**.
2. Enable the entry for the process that launched the viewer, adding it with
   **+** if it is not listed.
3. Back in the viewer, click **Input → Capture System Shortcuts**. It
   re-checks the grant right then; no restart, no polling.

TCC attributes the grant to the **responsible process**, not to the binary:
running `build/spice-viewer` from a shell, the grant belongs to the *terminal
application*, and every viewer started from that terminal inherits it. Bundled
as a `.app` later, the bundle is its own responsible process and needs its own
grant — a fresh entry in that list, not an inherited one.

Without the grant nothing breaks: the tap is never created, the menu item
reads "Capture System Shortcuts (needs Accessibility)", and tier 1 works as
described above. `VSM_NO_EVENT_TAP=1` forces that state on a machine that has
the grant, which is how it is tested.

### Escaping capture from the keyboard

Press **⌃⌥ together and release them** with no other key in between: capture
turns off. It is the same gesture that ungrabs the mouse, it is always handled
locally and never forwarded, and it works even when every ⌘ chord belongs to
the guest. Because a chord is only recognisable on release, the two presses
have already reached the guest by then — so firing it also releases every key
the guest still holds, and the log says how many. Turn capture back on from
the Input menu.

Capture also suspends itself, releasing the guest's keys each time, when the
viewer window stops being key, when the application is deactivated, and when
the session disconnects. It resumes when the window is key again.

### The ⌘Q rule

⌘Q is the one chord with a split personality, because a guest bound on SUPER
uses SUPER+Q constantly (Omarchy closes a window with it) and a Mac user
reaches for ⌘Q to quit:

| state | ⌘Q does |
| --- | --- |
| captured, with the event tap | **tap:** SUPER+Q to the guest. **hold ~1 s:** quits the viewer, showing a "Hold ⌘Q to Quit" overlay while the key is down |
| captured, no event tap | goes to the guest (there is no key-up to time a hold with); quit from the menu |
| not captured — capture off, no session, or a modal dialog is up | quits immediately, exactly as before |

Chrome's hold-to-quit, and UTM's "captured means the guest gets it". The
decision lives in one place, `-quitActionForKeyDown:`, which both the event
tap and the local ⌘Q key monitor ask, so the two cannot race to different
answers. Quitting on a hold releases the forwarded press first, so the guest
is never left holding SUPER+Q.

The chord is matched on `-characters`, not `-charactersIgnoringModifiers`:
with a non-Latin layout active (Russian, Greek, …) the latter is that layout's
own letter and ⌘Q would never be recognised. Only ⌘ may be down — Caps Lock
and the bits macOS adds to a tapped event are ignored.

**Send Key** exists for the chords that never arrive: ones macOS owns, and
ones (Ctrl+Alt+Del) that a Mac keyboard cannot express. Each item carries its
chord as a list of XT scancodes and goes through one shared
`-[VsmView sendChord:]`, which presses every code in order and releases them
in reverse order — what a human pressing the same combination produces.
PrintScreen is sent as the single extended code `0xe037`; the fake-shift
prefix a PS/2 controller adds is deliberately not synthesised, because guests
read `0xe037` as SysRq on its own and the extra `0xe02a` would look like a
real shift press.

### Fullscreen and window sizing

The window is `NSWindowCollectionBehaviorFullScreenPrimary`, so fullscreen is
the native macOS kind: its own Space, the green button, ctrl+⌘F, and the
standard View menu item. Outside fullscreen the window's proportions are
locked to the guest's (`contentAspectRatio`), so a drag cannot letterbox the
image. That constraint has to be dropped for the transition — AppKit will not
grow an aspect-locked window to fill a screen — so the window takes
`resizeIncrements = (1, 1)` on the way in and the lock is restored on the way
out.

In fullscreen the guest image aspect-fits inside a screen-sized view with
black bars: the view's layer is `kCAGravityResizeAspect` over an opaque black
background, and the window's background colour matches. The same aspect-fit
arithmetic backs `-guestPointFor:x:y:`, so a click in fullscreen lands where
it points; a click inside a black bar maps to no guest pixel and sends no
motion.

If the display's aspect ratio happens to match the guest's, fullscreen fills
it exactly and there are no bars. On a 2x panel whose point size exceeds the
guest resolution the image is magnified with `kCAFilterNearest`, so guest
pixels stay square and hard-edged rather than being smoothed.

**Guest resolution changes** are handled: a guest changes video mode by
destroying and recreating its primary surface, so `primary_create` arrives
again mid-session with new dimensions. Everything derived from the old size is
recomputed — the layer is rebound to the new IOSurface, the aspect lock is
updated, and the window is resized to the new guest pixel count. In fullscreen
the frame belongs to the screen, so only the letterboxing changes (the layer's
gravity has already done it) and the aspect lock is reapplied on the way out.


### Cursor

The cursor channel is connected for display 0 and gives the local pointer the
guest's shape. spice-client-glib is watched through `notify::cursor` rather
than the `::cursor-set` signal — same payload, but `cursor-set` has been
deprecated since spice-gtk 0.34 — plus `cursor-hide` and `cursor-reset`.

The shape arrives as premultiplied RGBA (`channel-cursor.c` byte-swaps its
BGRA words before handing it over), which is exactly what
`NSBitmapImageRep` wants with `bitmapFormat: 0`, so the bitmap is a straight
`memcpy` and the `NSImage` built from it becomes an `NSCursor` with the
guest's hotspot. The shape is copied on the GLib thread — the channel may
recycle its buffer as soon as the handler returns — and the copy is handed
to the main thread, which owns and frees it.

**The shape is treated as 1x points.** A 24x24 guest cursor becomes a 24x24
*point* image, so it is the right size next to guest content at any window
scale; on a Retina panel that means it is drawn at 2 physical pixels per
cursor pixel and is correspondingly softer than a native macOS cursor. A
sharp 2x cursor would have to come from the guest, and SPICE has no way to
ask for one.

The cursor is applied with `-[NSView addCursorRect:cursor:]`, so it is in
force only while the pointer is inside the guest area: over the title bar,
over another window or anywhere else on the desktop the pointer is whatever
the system would otherwise show. A define that arrives while the pointer is
already inside the view also sets the cursor directly, but only when the
viewer is the key window — `mouseLocationOutsideOfEventStream` reports the
pointer in this window's coordinates whether or not this window is the one
under it, so an occluded viewer would otherwise repaint the pointer on top of
another app.

`cursor-hide` shows a fully transparent 1x1 cursor through that same cursor
rect. It deliberately does not call `-[NSCursor hide]`: that is
application-global and unbalanced hide/unhide state survives focus changes,
so a guest that hid its pointer could leave the user with no pointer at all.
`cursor-reset` drops the guest shape and falls back to the system arrow.

Not handled: `cursor-move` (the server telling the client where to draw the
pointer) is only meaningful in server/relative mouse mode, which this build
does not implement.

Note that a guest which composites its pointer into the framebuffer instead
of using the cursor plane never sends a shape at all — it sends
`SPICE_CURSOR_FLAGS_NONE` at channel init, which arrives as `cursor-hide`,
and the pointer the user sees is the one drawn in the guest's own pixels.
That is the correct outcome: without hiding the local pointer there would be
two of them.

### Connect window, authentication and disconnects

`vsm-connect.m` owns everything the user sees when there is no session on
screen; `main.m` owns the state machine that moves between them:

```
connect window  --Connect-->  connected  --disconnect--> modal alert
       ^                          ^                          |
       +------- Close ------------+------ Reconnect ---------+
```

A session is never reused. Reconnecting — and retrying after an
authentication failure — stops the GLib thread, releases the `VsmSpice` and
builds a fresh one, because a `SpiceSession` that has errored out is finished
as far as spice-client-glib is concerned. `vsm_spice_free()` defers the actual
release to the main queue: callbacks already dispatched from the GLib thread
still hold the struct, and the main queue is FIFO, so a block appended after
the thread is joined runs strictly after all of them.

**Authentication.** `SPICE_CHANNEL_ERROR_AUTH` is the one failure a password
can fix, so the `disconnected` callback carries an `auth_failed` flag to
separate it from every other cause. On an auth failure the viewer raises an
`NSAlert` with an `NSSecureTextField` accessory (`Password for <uri>`),
then rebuilds the session with `vsm_spice_set_password()` before
`vsm_spice_start()`. The password is applied to the session's `password`
property on the GLib thread, at session construction, so it is never touched
from two threads. It lives in process memory for the run and is reused for
later reconnects; the C-side copy is overwritten (through a `volatile`
pointer, so the stores cannot be optimised away) before it is freed. It is
never written to `NSUserDefaults`, never logged and never emitted by
`VSM_TRACE`.

**Errors and disconnects.** Any other terminal failure raises an alert
showing the reason with **Reconnect** (default, Return) and **Close**
(Escape). Close returns to the connect window; the process keeps running. The
same alert appears for a connection that was up and then dropped, so a guest
reboot no longer kills the client.

Closing the viewer window ends the session and hands the user back to the
connect window. Closing the connect window quits — with no session on screen
it is the app's last exit door.

**⌘Q under a modal dialog.** AppKit disables the main menu for the duration
of a modal session, so the Quit menu item alone would strand the user behind
the password prompt or the disconnect alert. A local `NSEventMaskKeyDown`
monitor sees ⌘Q before it reaches the responder chain, in the modal run loop
as well as the normal one, and terminates.

The two alerts set their icon explicitly (caution, and a lock for the password
prompt). `NSAlert` otherwise badges the *application* icon, and a bare
un-bundled binary has none, so the default would be a generic folder.

### Mouse

Absolute (client) mode only, via `spice_inputs_channel_position()`. View points
are converted to guest pixels through the same aspect-fit transform the layer
uses, so the pointer lands where it looks like it lands even when the window is
not at its natural size. Buttons and a running button-state mask go through
`spice_inputs_channel_button_press/release()`; the scroll wheel is sent as
`BUTTON_UP`/`BUTTON_DOWN` press-release pairs, with trackpad fractional deltas
accumulated into whole notches.

### Relative (server) mouse mode

When the guest has no absolute pointing device the server negotiates **server
mode**, where the client sends pointer *deltas* rather than positions. The mode
arrives as `notify::mouse-mode` on the main channel and is pushed to the view
as `VsmSpiceCallbacks.mouse_mode`; absolute mode is unaffected by any of the
below.

**Taking the pointer.** Clicking the view grabs it (and the grab is taken
automatically on the mode switch itself if the window is already key). That
click is *consumed*: forwarding it as well would fire whatever sits under a
guest pointer the user cannot see yet. The grab is
`CGAssociateMouseAndMouseCursorPosition(false)` plus one
`CGWarpMouseCursorPosition()` to the view's centre — the local pointer then
stops moving entirely, so it can never reach a screen edge, another window or
another display, while `NSEvent.deltaX/.deltaY` keep reporting the hardware
movement. The local cursor is hidden over the view with the same transparent
1x1 cursor rect the guest's own `cursor-hide` uses. Sub-pixel deltas are
accumulated, exactly like the scroll wheel, so slow trackpad movement is not
rounded away.

**Giving it back.** ⌃⌥ pressed together and released with nothing in between —
virt-viewer's own convention, and the same chord that already turns keyboard
capture off. While the grab is held the window title gains
`(press ⌃⌥ to release)`; the suffix is composed from a stored base title rather
than appended in place, so a title update from the guest mid-grab cannot lose it
and an un-grab cannot leave it behind.

The chord cannot be recognised until both keys are *up*, by which time both
presses have already reached the guest — so firing it also releases every key
the guest holds, and swallows the chord's own key-ups. That is why ⌃⌥ never
leaves a stuck modifier behind. It is recognised in one place,
`-[VsmView noteEscapeChord:]`, and driven from both keyboard entry points (the
event tap when there is an Accessibility grant, `-flagsChanged:` otherwise), so
the two cannot drift apart.

**One un-grab function.** A pointer left disassociated is the worst failure
this code can produce — the user's whole desktop stops answering the mouse — so
every exit goes through `-[VsmView ungrabPointer:]`, and that function calls
`CGAssociateMouseAndMouseCursorPosition(true)` *first and unconditionally*,
before it looks at any state. The paths into it: the ⌃⌥ chord (both keyboard
entry points), the window resigning key, the application deactivating, a mode
switch back to absolute, session teardown (disconnect, window close, reconnect)
and quit — the last two via `-teardownSession`, which every quit path already
runs. As a final backstop the association is process-scoped: it is restored by
the kernel if the viewer is killed while grabbed.

Any button still held when the grab ends is released on the guest first: its
`mouseUp` would otherwise go wherever the freed pointer went, leaving the guest
with a button down for ever.

**Known gap.** The guest's pointer *position* is not drawn by the client. In
absolute mode it does not need to be — the local pointer is in the same place —
but in relative mode the server owns the position and reports it with the
cursor channel's `cursor-move`, which is traced (`VSM_TRACE=1`) but not
rendered. Whether that is visible depends on the guest: one that composites its
pointer into the framebuffer (the test guest does) looks right, one that uses
the cursor plane shows no pointer at all while grabbed. Rendering it is the
natural next ticket.

**Testing it.** Most guests run an agent and therefore negotiate absolute mode,
so `VSM_FORCE_RELATIVE=1` asks for server mode once, from the mouse-mode
notification — *not* at `channel-new`, because the request is a message on the
main channel and there is nothing to send it down until the server has
announced a mode. It asks only once: a retry on every announcement would be a
loop if the server refused. `VSM_GRAB_SELFTEST=1` then replays the whole
gesture.

One thing that self-test learned the hard way: **spice-gtk drops motion
messages when un-acknowledged ones pile up**, so a burst of `mouseMoved:` posted
in a single turn of the run loop mostly evaporates. Real hardware paces itself;
a script has to, and `drive_motion()` in `vsm-debug.m` sends one event every
25 ms.

### Clipboard

Plain **UTF-8 text**, both directions, on the `CLIPBOARD` selection only.
Images, rich text, file lists and the X11 `PRIMARY` selection are deliberately
out: macOS has no `PRIMARY`, and anything that is not text is dropped rather
than mistranslated. `vsm-spice.c` owns the SPICE half, `vsm-clipboard.m` the
AppKit half; the five `clipboard_*` entries in `VsmSpiceCallbacks` cross from
the GLib thread to the main thread, and the five `vsm_spice_clipboard_*`
functions cross back.

**It needs `spice-vdagent` running in the guest.** Without an agent the server
has nowhere to forward the messages, so the whole feature turns itself off:
one `guest agent absent: clipboard disabled` line at connect and no pasteboard
poll at all. "Present" means two things, and they become true a beat apart —
the `agent-connected` property AND the `CLIPBOARD_BY_DEMAND` capability. Both
are required before the first grab: calling
`spice_main_channel_clipboard_selection_grab()` on a connected agent whose
capability set has not landed yet trips a `g_return_if_fail` inside
spice-client-glib (`GSpice-CRITICAL agent_clipboard_grab`). A guest that never
brings an agent up says nothing at all, so a one-shot 1.5 s probe after the
main channel opens reports the state either way.

**A present agent is not a working one.** An agent can speak the protocol
correctly and still be wired to nothing: it answers our offer with a request,
takes the bytes, and never installs them as the guest's selection — and it
never announces the guest's own copies back to us. Seen on a Hyprland
(Wayland) guest, where `wl-copy`/`wl-paste` act on the Wayland selection while
upstream `spice-vdagent`'s clipboard backend is X11 and the service comes up
without a `DISPLAY`. The symptom to recognise is a trace that looks perfect —
`offering text to guest`, `guest requested UTF8 text`, `host -> guest, N bytes`
— while `wl-paste` in the guest still shows the old value and no guest grab
ever arrives. Nothing on the client side can fix that; the fix is in the
guest's agent setup.

**Host → guest is polled**, because AppKit posts no notification for a
pasteboard this process does not own. `NSPasteboard.general.changeCount` is
read once a second — but only while all three of "a session exists", "an agent
is connected" and "the application is active" hold, so a viewer sitting in the
background does not wake the CPU once a second. A change with text on it
*offers* the text to the guest (`clipboard_selection_grab`); the bytes are read
and sent only when the guest asks for them, which is usually within a hundred
milliseconds because a guest clipboard manager pulls them straight away. The
first poll of a new session deliberately treats whatever is already on the
pasteboard as fresh, so text copied *before* connecting is offered too.

Only a **non-empty** string is offered. `pbcopy </dev/null` leaves the text
flavour on the pasteboard with zero characters behind it, so the flavour alone
is not enough to go on and the poll reads the string to measure it; an empty
copy produces no grab at all.

**Every guest request is answered exactly once**, including the ones that
cannot be fulfilled: the pasteboard can be cleared in the ~50 ms between the
grab and the guest's request, and then the answer is an empty
`VD_AGENT_CLIPBOARD_NONE` notify (`vsm_spice_clipboard_send_none()`, traced as
`host -> guest, none (0 bytes)`) rather than silence. spice-gtk closes the same
case the same way (`spice-gtk-session.c`, `clipboard_received_cb`). Saying
nothing leaves the guest agent waiting on a reply that never arrives, and an
agent stuck there ignores every later grab — observed against a Linux guest
before this was added.

**Guest → host is event-driven.** The guest's grab is answered with a request
for `VD_AGENT_CLIPBOARD_UTF8_TEXT`, and the text that comes back is written to
`NSPasteboard.general` (`clearContents` + `setString:forType:`). The agent's
payload is not NUL-terminated on the wire, so `vsm-spice.c` copies it into a
NUL-terminated block on the GLib thread and hands ownership to the main thread.

The two halves would chase each other's tails if they were left alone: writing
the pasteboard bumps `changeCount`, which the poller would read as a fresh host
copy and offer straight back to the guest. Two guards break the loop — text
identical to what is already on the pasteboard is never written at all, and a
write that does happen records the `changeCount` it produced as already seen.
spice-gtk's `spice-gtk-session.c` carries the same guard for the same reason.

Clipboard **contents are never logged**. `VSM_TRACE=1` records the direction,
the type and a byte or character count, and nothing else; a marker string put
on the pasteboard does not appear anywhere in the trace.

## URLs and .vv files

The bundle declares two LaunchServices entry points in `Info.plist`, and both
land on the same code in `main.m`:

- **`spice://` and `spice+tls://` URLs** — `-application:openURLs:`. `spice` is
  claimed with `LSHandlerRank` `Owner` (nothing else on macOS handles it);
  `spice+tls` is declared alongside it and passed to spice-client-glib
  unchanged, which understands that scheme. Any other scheme is refused with an
  alert rather than handed to the session, where it would come back as a
  misleading "connection failed".
- **`.vv` connection files** — double-clicked in Finder, or opened with
  `open -a "SPICE Viewer.app" file.vv`.

Both work whether the app is already running or is being started by the open
itself. If a session is **already connected**, an open request is refused with
a one-button *"Already connected — disconnect the current session first"* alert
and the running session is left alone: this viewer shows one display, and
dropping a live session because a stale `.vv` was double-clicked would be the
wrong trade.

Two macOS delivery quirks are handled in `main.m` and are easy to reintroduce:

- Since macOS 10.13, a delegate that implements `-application:openURLs:` also
  receives **file** opens there, as `file://` URLs;
  `-application:openFile:` is not called. A `file://` URL fed to the session
  produces "connection failed" on a perfectly good `.vv` file.
- A **bundled** app receives its command-line argument through
  `-application:openFile:`, not on `argv`. A `spice://` argument therefore
  arrives on the document path and has to be classified before use.

Open requests can also arrive *before* `-applicationDidFinishLaunching:` — that
is how Finder starts the app in the first place — so the handlers record what
they were asked for and let the launch finish the job. Nothing flashes the
connect window on the way to a connection.

### What a .vv file may contain

Parsed with `GKeyFile` (`vsm-vv.c`), group `[virt-viewer]`:

| key | effect |
| --- | --- |
| `type` | must be `spice`; anything else is an alert ("This connection file is for … displays") |
| `host` | required |
| `port` | required, 1–65535; a bare IPv6 literal is bracketed when the URI is built |
| `password` | optional, used for the session and never written to defaults or logged |
| `delete-this-file` | `1` deletes the file once it has been accepted |

**Every other key and group is logged once with `g_message()` and ignored**, so
a file from a real oVirt deployment — which carries a couple of dozen keys this
viewer knows nothing about — still connects. That includes `tls-port` and `ca`:
TLS is not wired up yet, and a `.vv` that only offers a TLS port fails the
host/port check with an alert rather than connecting in the clear.

`delete-this-file=1` is honoured only when the connection is accepted. A file
the viewer refused to open (wrong `type`, or a session already on screen) is
left on disk, because the user still needs it.

## Layout

| file | role |
| --- | --- |
| `main.m` | `NSApplication`, session state machine, window, menu, and the `VsmView` responder methods |
| `main-view.h` | the `VsmView` interface, shared with the debug helpers |
| `vsm-clipboard.m/.h` | the AppKit half of the text clipboard: pasteboard poll, echo guards |
| `vsm-connect.m/.h` | connect window, password prompt, disconnect alert |
| `vsm-tap.m/.h` | the `CGEventTap` that captures the system-reserved chords |
| `vsm-spice.c/.h` | GLib thread, session and channel wiring, damage blit, input marshalling |
| `vsm-keymap.c/.h` | generated osx → xtkbd scancode table |
| `vsm-debug.m/.h` | framebuffer PNG dump, the scripted input self-test, the synthetic cursor self-test, the send-key chord self-test and the pointer-grab self-test |
| `vsm-vv.c/.h` | `.vv` connection-file parser |
| `build.sh` | the build |
| `make-bundle.sh` | the `.app` bundler (naming placeholders live at the top) |
| `Info.plist.in` | bundle metadata template: URL schemes, `.vv` document type |
