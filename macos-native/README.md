# Native macOS SPICE viewer — proof of concept

A standalone SPICE client for macOS with **no GTK anywhere**: spice-client-glib
for the protocol, AppKit/Core Animation for the window, and a keycodemapdb
scancode table for the keyboard.

Scope so far: **screen, keyboard, absolute mouse, guest cursor shape.** There
is deliberately no clipboard, no file transfer, no USB redirection, no audio,
no relative ("server") mouse mode, and no multi-display support.

## Build

```
bash macos-native/build.sh
```

That is the whole build. It does not touch the project's meson build and
produces `macos-native/build/spice-viewer`.

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
macos-native/build/spice-viewer spice://HOST:PORT
```

`spice://HOST:PORT` above is a placeholder — the URI is read from `argv[1]`,
never from a compiled-in default.

⌘Q quits: every key still held is released on the guest, the session is
disconnected and the GLib thread is joined before the process exits.

### Environment variables

| variable | effect |
| --- | --- |
| `VSM_TRACE=1` | log every scancode, damage rect, motion, button and scroll event, and every cursor define/hide/reset |
| `VSM_DUMP_DIR=<dir>` | `SIGUSR1` writes the current guest framebuffer to `<dir>/frame-N.png` |
| `VSM_SELFTEST=1` | two seconds after the first frame, replay a fixed benign input script (arrows, Escape, each modifier, absolute motion, left/right click, scroll) through the real responder methods |
| `VSM_CURSOR_SELFTEST=1` | two seconds after the first frame, drive a synthetic cursor script (two shapes with different hotspots, then hide, then reset) through the real cursor code path |
| `VSM_CURSOR_CHURN=N` | with `VSM_CURSOR_SELFTEST`, replace the cursor N times as fast as possible first, so `leaks(1)` can show there is no per-define leak |
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

### Mouse

Absolute (client) mode only, via `spice_inputs_channel_position()`. View points
are converted to guest pixels through the same aspect-fit transform the layer
uses, so the pointer lands where it looks like it lands even when the window is
not at its natural size. Buttons and a running button-state mask go through
`spice_inputs_channel_button_press/release()`; the scroll wheel is sent as
`BUTTON_UP`/`BUTTON_DOWN` press-release pairs, with trackpad fractional deltas
accumulated into whole notches.

If the guest asks for server (relative) mouse mode, that is logged and ignored
rather than half-implemented — see the gap list in the ticket report.

## Layout

| file | role |
| --- | --- |
| `main.m` | `NSApplication`, window, menu, and the `VsmView` responder methods |
| `main-view.h` | the `VsmView` interface, shared with the debug helpers |
| `vsm-spice.c/.h` | GLib thread, session and channel wiring, damage blit, input marshalling |
| `vsm-keymap.c/.h` | generated osx → xtkbd scancode table |
| `vsm-debug.m/.h` | framebuffer PNG dump, the scripted input self-test and the synthetic cursor self-test |
| `build.sh` | the build |
