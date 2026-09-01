/*
 * main.m: native macOS front end for the SPICE viewer PoC.
 *
 * No GTK.  An NSWindow whose content view is a plain layer-backed NSView;
 * the layer's contents is the IOSurface that vsm-spice.c blits guest damage
 * into.  Handing CA an IOSurface directly means the damaged pixels are the
 * only ones we copy, and the compositor samples them 1:1 against physical
 * display pixels (contentsScale = backingScaleFactor), so a Retina screen
 * shows the guest framebuffer with no interpolation at all.
 *
 * Usage: viewer [spice://host:port].  With a URI the viewer connects to it
 * straight away; with no arguments it opens the connect window instead (see
 * vsm-connect.m) and the session state machine below drives the rest.
 */
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

#include "main-view.h"
#include "vsm-connect.h"
#include "vsm-debug.h"
#include "vsm-keymap.h"
#include "vsm-spice.h"
#include "vsm-tap.h"
#include "vsm-vv.h"

/* Device-dependent modifier bits (IOKit's IOLLEvent.h), used to tell left
 * from right on flagsChanged: the public NSEventModifierFlag* masks collapse
 * both physical keys into one bit. */
enum {
    VSM_DEV_LCTRL  = 0x00000001,
    VSM_DEV_LSHIFT = 0x00000002,
    VSM_DEV_RSHIFT = 0x00000004,
    VSM_DEV_LCMD   = 0x00000008,
    VSM_DEV_RCMD   = 0x00000010,
    VSM_DEV_LALT   = 0x00000020,
    VSM_DEV_RALT   = 0x00000040,
    VSM_DEV_RCTRL  = 0x00002000,
};

/* macOS virtual keycodes for the modifier keys. */
enum {
    VSM_KC_LSHIFT = 0x38, VSM_KC_RSHIFT = 0x3C,
    VSM_KC_LCTRL  = 0x3B, VSM_KC_RCTRL  = 0x3E,
    VSM_KC_LALT   = 0x3A, VSM_KC_RALT   = 0x3D,
    VSM_KC_LCMD   = 0x37, VSM_KC_RCMD   = 0x36,
    VSM_KC_CAPS   = 0x39,
};

/* How long ⌘Q has to be held before it quits the viewer instead of typing
 * SUPER+Q into the guest (Chrome's hold-to-quit, same duration). */
static const NSTimeInterval VSM_QUIT_HOLD_SECONDS = 1.0;

static BOOL vsm_trace;   /* VSM_TRACE=1: log every scancode/mouse event */

@implementation VsmView {
    NSMutableSet<NSNumber *> *_heldModifierKeyCodes;
    int _buttonState;
    NSCursor *_guestCursor;   /* the guest's shape, nil = system arrow */
    BOOL _cursorHidden;       /* guest asked for no pointer at all */
}

- (instancetype)initWithFrame:(NSRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        _heldModifierKeyCodes = [NSMutableSet set];
        /* Default ON: the guests this viewer is built for bind their window
         * manager on SUPER, so Cmd has to reach them unless the user says
         * otherwise (see -performKeyEquivalent:). */
        _captureKeyboard = YES;
        self.wantsLayer = YES;
        self.layer.backgroundColor = NSColor.blackColor.CGColor;
        self.layer.contentsGravity = kCAGravityResizeAspect;
        /* The guest framebuffer is not a resampled image; keep every
         * transition between guest pixels hard. */
        self.layer.magnificationFilter = kCAFilterNearest;
        self.layer.minificationFilter = kCAFilterTrilinear;
    }
    return self;
}

- (BOOL)acceptsFirstResponder    { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (BOOL)isFlipped                { return YES; }

- (void)viewDidChangeBackingProperties
{
    [super viewDidChangeBackingProperties];
    self.layer.contentsScale = self.window.backingScaleFactor;
}

/* Rebind the layer to the current IOSurface so CA re-reads its bytes.
 * Assigning the same object twice is a no-op to CA, so unbind first; both
 * assignments sit inside one transaction with actions disabled, which means
 * the intermediate nil never reaches the screen (no flash) and no implicit
 * animation is created. */
- (void)refreshSurface
{
    IOSurfaceRef surface = vsm_spice_copy_surface(self.spice);
    if (!surface)
        return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.contents = nil;
    self.layer.contents = (__bridge id)surface;
    [CATransaction commit];
    CFRelease(surface);
}

/* ------------------------------------------------------------- keyboard */

- (void)sendKeyCode:(unsigned short)keyCode down:(BOOL)down
{
    unsigned scancode = (keyCode < 256) ? osx_to_xtkbd[keyCode] : 0;

    if (vsm_trace)
        NSLog(@"key %@ osx=0x%02x -> xt=0x%04x",
              down ? @"down" : @"up  ", keyCode, scancode);
    if (!scancode) {
        NSLog(@"no XT scancode for macOS keycode 0x%02x", keyCode);
        return;
    }
    vsm_spice_send_key(self.spice, scancode, down ? 1 : 0);
}

- (void)keyDown:(NSEvent *)event
{
    if (self.tapOwnsKeyboard)
        return;                       /* the tap already forwarded this one */
    if (event.isARepeat) {
        /* Let the guest run its own repeat rate: re-press only. */
        [self sendKeyCode:event.keyCode down:YES];
        return;
    }
    [self sendKeyCode:event.keyCode down:YES];
}

- (void)keyUp:(NSEvent *)event
{
    if (self.tapOwnsKeyboard)
        return;
    [self sendKeyCode:event.keyCode down:NO];
}

/* AppKit offers every Cmd chord to the key window's view hierarchy before it
 * reaches the main menu, so this is where keyboard capture is enforced: while
 * it is on and a session is live, EVERY Cmd chord is consumed here and sent
 * to the guest, and the app's own shortcuts (Cmd-Q, Cmd-0, ctrl-Cmd-F) stop
 * working until capture is turned off from the menu with the mouse.  That is
 * deliberate -- a guest bound on SUPER is unusable if the client keeps a
 * handful of chords for itself.
 *
 * The Cmd key itself is not sent from here: it already reached the guest via
 * flagsChanged: when it went down, and its release will arrive the same way.
 * Only the non-modifier key of the chord needs a press/release pair, and it
 * needs both, because a key equivalent never produces a matching keyUp.
 *
 * With the event tap installed this is dead code for captured chords -- the
 * tap consumed them long before AppKit looked for a key equivalent -- and
 * stands aside for anything the tap deliberately passed through. */
- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    if (self.tapOwnsKeyboard)
        return NO;
    if (!self.captureKeyboard || !self.spice)
        return NO;
    if (!self.window.isKeyWindow || self.window.firstResponder != self)
        return NO;
    if (!(event.modifierFlags & NSEventModifierFlagCommand))
        return NO;

    [self sendKeyCode:event.keyCode down:YES];
    [self sendKeyCode:event.keyCode down:NO];
    return YES;
}

- (void)sendChord:(NSArray<NSNumber *> *)scancodes
{
    for (NSNumber *code in scancodes) {
        if (vsm_trace)
            NSLog(@"chord press   xt=0x%04x", code.unsignedIntValue);
        vsm_spice_send_key(self.spice, code.unsignedIntValue, 1);
    }
    for (NSNumber *code in scancodes.reverseObjectEnumerator) {
        if (vsm_trace)
            NSLog(@"chord release xt=0x%04x", code.unsignedIntValue);
        vsm_spice_send_key(self.spice, code.unsignedIntValue, 0);
    }
}

/* macOS never delivers keyDown/keyUp for modifiers; it delivers one
 * flagsChanged per physical transition.  Derive press vs release from the
 * device-dependent bit for that specific key, falling back to the generic
 * mask when the driver does not set one. */
- (void)flagsChanged:(NSEvent *)event
{
    if (self.tapOwnsKeyboard)
        return;
    [self handleFlagsChanged:event];
}

- (void)handleFlagsChanged:(NSEvent *)event
{
    NSUInteger flags = event.modifierFlags;
    unsigned short kc = event.keyCode;
    NSUInteger devBit = 0, genericBit = 0;
    BOOL down;

    /* Cmd is the one modifier the toggle owns: with capture off the app keeps
     * its shortcuts, and letting the bare Cmd press through anyway would
     * still trip whatever the guest's window manager binds on SUPER. */
    if (!self.captureKeyboard && (kc == VSM_KC_LCMD || kc == VSM_KC_RCMD))
        return;

    switch (kc) {
    case VSM_KC_LSHIFT: devBit = VSM_DEV_LSHIFT; genericBit = NSEventModifierFlagShift;   break;
    case VSM_KC_RSHIFT: devBit = VSM_DEV_RSHIFT; genericBit = NSEventModifierFlagShift;   break;
    case VSM_KC_LCTRL:  devBit = VSM_DEV_LCTRL;  genericBit = NSEventModifierFlagControl; break;
    case VSM_KC_RCTRL:  devBit = VSM_DEV_RCTRL;  genericBit = NSEventModifierFlagControl; break;
    case VSM_KC_LALT:   devBit = VSM_DEV_LALT;   genericBit = NSEventModifierFlagOption;  break;
    case VSM_KC_RALT:   devBit = VSM_DEV_RALT;   genericBit = NSEventModifierFlagOption;  break;
    case VSM_KC_LCMD:   devBit = VSM_DEV_LCMD;   genericBit = NSEventModifierFlagCommand; break;
    case VSM_KC_RCMD:   devBit = VSM_DEV_RCMD;   genericBit = NSEventModifierFlagCommand; break;
    case VSM_KC_CAPS:
        /* Caps Lock latches on macOS: one event per physical press, with the
         * flag toggling.  The guest wants a full press/release either way. */
        [self sendKeyCode:kc down:YES];
        [self sendKeyCode:kc down:NO];
        return;
    default:
        return;
    }

    down = (flags & devBit) ? YES : (((flags & genericBit) && !(flags & 0x0000ffff)) ? YES : NO);

    NSNumber *key = @(kc);
    if (down == [_heldModifierKeyCodes containsObject:key])
        return;                       /* no transition for this key */
    if (down)
        [_heldModifierKeyCodes addObject:key];
    else
        [_heldModifierKeyCodes removeObject:key];
    [self sendKeyCode:kc down:down];
}

- (void)releaseAllKeys
{
    [_heldModifierKeyCodes removeAllObjects];
    _buttonState = 0;
    vsm_spice_release_all_keys(self.spice);
}

/* --------------------------------------------------------------- cursor */

/* A fully transparent 1x1 cursor.  This is how "the guest hid the pointer"
 * is expressed: -[NSCursor hide] is application-global and survives focus
 * loss, so it would leave the user with no pointer anywhere on the desktop
 * if the guest hid its cursor and the app then lost focus.  A transparent
 * image scoped to the view's cursor rect has neither problem. */
+ (NSCursor *)blankCursor
{
    static NSCursor *blank;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
        [image lockFocus];
        [NSColor.clearColor set];
        NSRectFill(NSMakeRect(0, 0, 1, 1));
        [image unlockFocus];
        blank = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
    });
    return blank;
}

/* The cursor actually shown while the pointer is inside the view. */
- (NSCursor *)effectiveCursor
{
    if (_cursorHidden)
        return [VsmView blankCursor];
    return _guestCursor ?: NSCursor.arrowCursor;
}

/* Cursor rects are per-view, so the pointer reverts to whatever the system
 * would otherwise show as soon as it leaves the guest area -- over the title
 * bar, over another window, anywhere outside. */
- (void)resetCursorRects
{
    [self addCursorRect:self.bounds cursor:[self effectiveCursor]];
}

/* Re-ask AppKit for the rects so a shape that changed while the pointer is
 * already inside the view takes effect immediately. */
- (void)refreshCursorRects
{
    NSPoint p = [self convertPoint:self.window.mouseLocationOutsideOfEventStream
                          fromView:nil];

    [self.window invalidateCursorRectsForView:self];
    /* mouseLocationOutsideOfEventStream reports the pointer in this window's
     * coordinates whether or not this window is the one under it, so the key
     * check matters: without it an occluded viewer would repaint the cursor
     * on top of whatever app the user is actually pointing at. */
    if (self.window.isKeyWindow && NSPointInRect(p, self.bounds))
        [[self effectiveCursor] set];
}

- (void)setGuestCursor:(NSCursor *)cursor
{
    /* ARC drops the previous NSCursor (and with it its NSImage and bitmap
     * backing) here, so a session's worth of cursor-defines costs one live
     * cursor, not thousands. */
    _guestCursor = cursor;
    _cursorHidden = NO;
    [self refreshCursorRects];
}

- (void)hideGuestCursor
{
    _cursorHidden = YES;
    [self refreshCursorRects];
}

- (void)resetGuestCursor
{
    _guestCursor = nil;
    _cursorHidden = NO;
    [self refreshCursorRects];
}

/* ---------------------------------------------------------------- mouse */

/* View point -> guest pixel, honouring the aspect-fit letterboxing that
 * kCAGravityResizeAspect applies. */
- (BOOL)guestPointFor:(NSEvent *)event x:(int *)outX y:(int *)outY
{
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSSize size = self.bounds.size;
    double gw = self.guestWidth, gh = self.guestHeight;
    double scale, drawW, drawH, originX, originY, gx, gy;

    if (gw <= 0 || gh <= 0 || size.width <= 0 || size.height <= 0)
        return NO;

    scale = MIN(size.width / gw, size.height / gh);
    drawW = gw * scale;
    drawH = gh * scale;
    originX = (size.width - drawW) / 2.0;
    originY = (size.height - drawH) / 2.0;

    gx = (p.x - originX) / scale;
    gy = (p.y - originY) / scale;
    if (gx < 0 || gy < 0 || gx >= gw || gy >= gh)
        return NO;

    *outX = (int)gx;
    *outY = (int)gy;
    return YES;
}

- (void)sendMotion:(NSEvent *)event
{
    int x = 0, y = 0;
    if (![self guestPointFor:event x:&x y:&y])
        return;
    if (vsm_trace)
        NSLog(@"motion %d,%d buttons=0x%x", x, y, _buttonState);
    vsm_spice_send_position(self.spice, x, y, _buttonState);
}

- (void)mouseMoved:(NSEvent *)event      { [self sendMotion:event]; }
- (void)mouseDragged:(NSEvent *)event    { [self sendMotion:event]; }
- (void)rightMouseDragged:(NSEvent *)e   { [self sendMotion:e]; }
- (void)otherMouseDragged:(NSEvent *)e   { [self sendMotion:e]; }

- (void)sendButton:(int)button mask:(int)mask down:(BOOL)down event:(NSEvent *)event
{
    [self sendMotion:event];
    if (down)
        _buttonState |= mask;
    else
        _buttonState &= ~mask;
    if (vsm_trace)
        NSLog(@"button %d %@ state=0x%x", button, down ? @"press" : @"release",
              _buttonState);
    vsm_spice_send_button(self.spice, button, down ? 1 : 0, _buttonState);
}

- (void)mouseDown:(NSEvent *)e       { [self sendButton:VSM_BUTTON_LEFT   mask:VSM_MASK_LEFT   down:YES event:e]; }
- (void)mouseUp:(NSEvent *)e         { [self sendButton:VSM_BUTTON_LEFT   mask:VSM_MASK_LEFT   down:NO  event:e]; }
- (void)rightMouseDown:(NSEvent *)e  { [self sendButton:VSM_BUTTON_RIGHT  mask:VSM_MASK_RIGHT  down:YES event:e]; }
- (void)rightMouseUp:(NSEvent *)e    { [self sendButton:VSM_BUTTON_RIGHT  mask:VSM_MASK_RIGHT  down:NO  event:e]; }
- (void)otherMouseDown:(NSEvent *)e  { [self sendButton:VSM_BUTTON_MIDDLE mask:VSM_MASK_MIDDLE down:YES event:e]; }
- (void)otherMouseUp:(NSEvent *)e    { [self sendButton:VSM_BUTTON_MIDDLE mask:VSM_MASK_MIDDLE down:NO  event:e]; }

- (void)scrollWheel:(NSEvent *)event
{
    /* Trackpads deliver fractional deltas; accumulate into whole notches. */
    static double accum;
    int steps;

    accum += event.hasPreciseScrollingDeltas
        ? event.scrollingDeltaY / 10.0
        : event.scrollingDeltaY;
    steps = (int)accum;
    if (!steps)
        return;
    accum -= steps;
    if (vsm_trace)
        NSLog(@"scroll %d steps", steps);
    vsm_spice_send_scroll(self.spice, steps, _buttonState);
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    for (NSTrackingArea *area in [self.trackingAreas copy])
        [self removeTrackingArea:area];
    [self addTrackingArea:
        [[NSTrackingArea alloc] initWithRect:self.bounds
                                     options:(NSTrackingMouseMoved |
                                              NSTrackingActiveInKeyWindow |
                                              NSTrackingInVisibleRect)
                                       owner:self
                                    userInfo:nil]];
}

@end

/* The hold-to-quit overlay's window.  It must never become key: the key it
 * is announcing is still physically down, and every remaining event of that
 * keystroke -- the release that cancels the hold, and the auto-suspend that
 * a viewer window losing key triggers -- depends on the viewer window
 * keeping focus while the panel is on screen. */
@interface VsmHUDPanel : NSPanel
@end

@implementation VsmHUDPanel
- (BOOL)canBecomeKeyWindow  { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

/* ------------------------------------------------------------- delegate */

/* What ⌘Q means right now.  One enum, one decision point
 * (-quitActionForKeyDown:), two callers: the event tap and the local key
 * monitor.  They used to race for the chord; now they ask the same question
 * and only one of them is in a position to act on the answer. */
typedef enum {
    VSM_QUIT_NONE,   /* not the quit chord, or the guest simply gets it */
    VSM_QUIT_HOLD,   /* captured: goes to the guest, ~1 s hold quits */
    VSM_QUIT_NOW,    /* not captured: quit immediately */
} VsmQuitAction;

@interface VsmAppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate,
                                      VsmEventTapDelegate>
@property (nonatomic, strong) NSWindow *window;
@property (nonatomic, strong) VsmView *view;
@property (nonatomic, assign) VsmSpice *spice;
@property (nonatomic, copy)   NSString *uri;
/* The password typed into the auth prompt during THIS run, reused for
 * reconnects.  Process memory only: never written to defaults or logged. */
@property (nonatomic, copy)   NSString *password;
@property (nonatomic, strong) VsmConnectWindowController *connectWindow;
/* Set while a modal disconnect/auth dialog is up, so the extra disconnect
 * callbacks other channels queue do not stack a second alert on top. */
@property (nonatomic, assign) BOOL handlingDisconnect;
@property (nonatomic, strong) id quitMonitor;
@property (nonatomic, strong) NSMenuItem *captureItem;
/* The system-shortcut tier: nil until the first enable, and installed only
 * with an Accessibility grant.  Everything else works without it. */
@property (nonatomic, strong) VsmEventTap *tap;
@property (nonatomic, strong) NSMenuItem *tapItem;
/* macOS shows its Accessibility dialog at most once per run of the viewer:
 * a prompt on every toggle would be a prompt loop. */
@property (nonatomic, assign) BOOL promptedForAccessibility;
/* ⌃⌥ went down together with nothing else held -- if both come back up
 * before any other key is pressed, that is the escape chord. */
@property (nonatomic, assign) BOOL escapeArmed;
/* Running while ⌘Q is held; firing quits, letting go cancels. */
@property (nonatomic, strong) NSTimer *quitHoldTimer;
@property (nonatomic, assign) unsigned short quitHoldKeyCode;
@property (nonatomic, strong) NSPanel *quitHUD;
/* Last value -captureActive returned, so the edges get logged once each. */
@property (nonatomic, assign) BOOL captureWasActive;
@property (nonatomic, strong) dispatch_source_t dumpSource;
/* NO until -applicationDidFinishLaunching: has run.  LaunchServices delivers
 * the URL or file that started the app BEFORE that point, so those handlers
 * record what they were asked for and let the launch finish the job. */
@property (nonatomic, assign) BOOL didFinishLaunching;
/* An open request that arrived before launch and could not be honoured; shown
 * as an alert once there is an app to show it in. */
@property (nonatomic, copy)   NSString *pendingOpenError;
@property (nonatomic, assign) BOOL selftestDone;
@property (nonatomic, assign) BOOL cursorSelftestDone;
@property (nonatomic, assign) BOOL sendkeySelftestDone;
@end

/* The callback bodies are the C glue at the bottom of the file; the table has
 * to exist up here because -connect installs it on every new session. */
static void cb_primary_create(void *user, int width, int height);
static void cb_damaged(void *user, int x, int y, int w, int h);
static void cb_title(void *user, const char *title);
static void cb_status(void *user, const char *status);
static void cb_disconnected(void *user, const char *reason, int auth_failed);
static void cb_cursor_define(void *user, int width, int height,
                             int hot_x, int hot_y, const uint8_t *rgba);
static void cb_cursor_hide(void *user);
static void cb_cursor_reset(void *user);

static const VsmSpiceCallbacks vsm_callbacks = {
    .primary_create = cb_primary_create,
    .damaged        = cb_damaged,
    .title          = cb_title,
    .status         = cb_status,
    .disconnected   = cb_disconnected,
    .cursor_define  = cb_cursor_define,
    .cursor_hide    = cb_cursor_hide,
    .cursor_reset   = cb_cursor_reset,
};

/* XT (AT set 1) scancodes for the Send Key chords.  0x1xx is the 0xe0-
 * prefixed extended form, the encoding spice_inputs_channel_key_press()
 * expects and the one vsm-keymap.c already uses. */
enum {
    VSM_XT_LCTRL     = 0x01d,
    VSM_XT_LSHIFT    = 0x02a,
    VSM_XT_LALT      = 0x038,
    VSM_XT_BACKSPACE = 0x00e,
    VSM_XT_F11       = 0x057,
    VSM_XT_DELETE    = 0x153,   /* e0 53, the editing-pad Delete */
    VSM_XT_PRTSCR    = 0x137,   /* e0 37 */
};

@implementation VsmAppDelegate

/* One Send Key entry: the chord it types lives in representedObject so every
 * item shares -sendKeyChord: and therefore the exact same send path. */
- (NSMenuItem *)sendKeyItem:(NSString *)title codes:(NSArray<NSNumber *> *)codes
{
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                  action:@selector(sendKeyChord:)
                                           keyEquivalent:@""];
    item.target = self;
    item.representedObject = codes;
    return item;
}

- (void)buildMenu
{
    NSMenu *bar = [[NSMenu alloc] init];
    NSMenuItem *appItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    NSMenuItem *viewItem = [[NSMenuItem alloc] init];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *inputItem = [[NSMenuItem alloc] init];
    NSMenu *inputMenu = [[NSMenu alloc] initWithTitle:@"Input"];
    NSMenu *sendMenu = [[NSMenu alloc] initWithTitle:@"Send Key"];
    NSMenuItem *item;

    [appMenu addItemWithTitle:@"Quit"
                       action:@selector(terminate:)
                keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];

    item = [viewMenu addItemWithTitle:@"Actual Size"
                               action:@selector(actualSize:)
                        keyEquivalent:@"0"];
    item.target = self;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    /* No target: toggleFullScreen: travels the responder chain to whichever
     * window is key, and AppKit keeps this item's title in sync with that
     * window's state ("Enter"/"Exit Full Screen") and disables it for windows
     * that cannot go fullscreen. */
    item = [viewMenu addItemWithTitle:@"Enter Full Screen"
                               action:@selector(toggleFullScreen:)
                        keyEquivalent:@"f"];
    item.keyEquivalentModifierMask = NSEventModifierFlagControl |
                                     NSEventModifierFlagCommand;
    viewItem.submenu = viewMenu;
    [bar addItem:viewItem];

    self.captureItem = [inputMenu addItemWithTitle:@"Capture Keyboard"
                                            action:@selector(toggleCaptureKeyboard:)
                                     keyEquivalent:@""];
    self.captureItem.target = self;
    /* The second capture tier.  Its title carries the Accessibility state
     * because that is the only thing the user can do anything about, and
     * clicking it is how a grant given after launch is picked up. */
    self.tapItem = [inputMenu addItemWithTitle:@"Capture System Shortcuts"
                                        action:@selector(captureSystemShortcuts:)
                                 keyEquivalent:@""];
    self.tapItem.target = self;
    [inputMenu addItem:[NSMenuItem separatorItem]];

    /* Chords the guest needs and AppKit or macOS would otherwise eat, each
     * spelled out as the scancodes a human would press. */
    [sendMenu addItem:[self sendKeyItem:@"Ctrl+Alt+Del"
                                  codes:@[@(VSM_XT_LCTRL), @(VSM_XT_LALT),
                                          @(VSM_XT_DELETE)]]];
    [sendMenu addItem:[self sendKeyItem:@"Ctrl+Alt+Backspace"
                                  codes:@[@(VSM_XT_LCTRL), @(VSM_XT_LALT),
                                          @(VSM_XT_BACKSPACE)]]];
    [sendMenu addItem:[self sendKeyItem:@"PrintScreen"
                                  codes:@[@(VSM_XT_PRTSCR)]]];
    [sendMenu addItem:[self sendKeyItem:@"F11" codes:@[@(VSM_XT_F11)]]];
    item = [inputMenu addItemWithTitle:@"Send Key" action:NULL keyEquivalent:@""];
    item.submenu = sendMenu;
    inputItem.submenu = inputMenu;
    [bar addItem:inputItem];

    NSApp.mainMenu = bar;
}

/* Targets are set explicitly above, so this is only asked about our own
 * actions; toggleFullScreen: is validated by the window itself. */
- (BOOL)validateMenuItem:(NSMenuItem *)item
{
    SEL action = item.action;

    if (action == @selector(toggleCaptureKeyboard:)) {
        item.state = self.view.captureKeyboard ? NSControlStateValueOn
                                               : NSControlStateValueOff;
        return YES;
    }
    if (action == @selector(captureSystemShortcuts:)) {
        BOOL trusted = [VsmEventTap isProcessTrusted:NO] &&
                       !NSProcessInfo.processInfo.environment[@"VSM_NO_EVENT_TAP"];

        /* Checked only when the tap is actually consuming for us: capture on,
         * tap installed.  Re-checking trust here (menu open, not a timer) is
         * how a grant made while the viewer runs is noticed without polling. */
        item.state = (self.tap.active && self.view.captureKeyboard)
                         ? NSControlStateValueOn : NSControlStateValueOff;
        item.title = trusted ? @"Capture System Shortcuts"
                             : @"Capture System Shortcuts (needs Accessibility)";
        return YES;
    }
    if (action == @selector(sendKeyChord:))
        return self.spice != NULL;
    if (action == @selector(actualSize:))
        return self.spice != NULL && ![self isFullScreen];
    return YES;
}

- (BOOL)isFullScreen
{
    return (self.window.styleMask & NSWindowStyleMaskFullScreen) != 0;
}

/* --------------------------------------------------------- menu actions */

- (void)toggleCaptureKeyboard:(id)sender
{
    (void)sender;
    [self setCapture:!self.view.captureKeyboard reason:@"menu"];
}

/* Clicking the system-shortcut item is both "I want this tier" and "look at
 * the Accessibility grant again": with a grant it installs the tap, without
 * one it shows the system dialog (once) and leaves everything else alone. */
- (void)captureSystemShortcuts:(id)sender
{
    (void)sender;
    if (self.tap.active) {
        [self.tap uninstall];
        [self updateKeyboardOwnership];
        NSLog(@"system shortcut capture off (event tap removed)");
        return;
    }
    if (![self installTapPrompting:YES])
        return;
    if (!self.view.captureKeyboard)
        [self setCapture:YES reason:@"system shortcut capture"];
}

/* ------------------------------------------------------- keyboard capture
 *
 * Two tiers.  Tier one is T-0025's: the responder methods forward whatever
 * AppKit hands the view.  Tier two is the CGEventTap, which additionally
 * gets the chords macOS keeps for itself -- Cmd-Space, Cmd-Tab, Cmd-` -- and
 * needs an Accessibility grant.  Tier two supersedes tier one completely
 * while it is installed (see -updateKeyboardOwnership), so no keystroke is
 * ever sent twice; with no grant only tier one exists and the app behaves
 * exactly as it did before.
 */

/* Is the guest receiving the keyboard right now?  Every reason capture can
 * stop -- the menu toggle, the escape chord, the window losing key, the app
 * deactivating, the session going away -- is expressed here and nowhere
 * else, so the tap, the quit policy and the log cannot disagree. */
- (BOOL)captureActive
{
    return self.view.captureKeyboard && self.spice != NULL &&
           self.window != nil && self.window.isKeyWindow && NSApp.isActive;
}

/* Log capture edges once each.  The auto-suspend cases are invisible
 * otherwise: nothing is sent, so a scancode trace shows only silence. */
/* An auto-suspend trigger fired.  Logged whether or not the state actually
 * moved: "did the tap stand down when the window lost focus?" is a question
 * about the trigger, and the answer is worthless if the line only appears
 * when capture happened to be active at the time. */
- (void)noteCaptureSuspendedBy:(NSString *)reason
{
    self.captureWasActive = [self captureActive];
    NSLog(@"capture auto-suspend: %@ (capture now %s)", reason,
          self.captureWasActive ? "active" : "inactive");
}

- (void)noteCaptureState:(NSString *)reason
{
    BOOL active = [self captureActive];

    if (active == self.captureWasActive)
        return;
    self.captureWasActive = active;
    NSLog(@"capture %s (%@)", active ? "resumed" : "suspended", reason);
}

- (void)setCapture:(BOOL)on reason:(NSString *)reason
{
    self.view.captureKeyboard = on;
    self.escapeArmed = NO;
    [self cancelQuitHold];
    /* Turning capture off mid-chord would otherwise leave whatever modifier
     * is physically down stuck down in the guest. */
    if (!on)
        [self.view releaseAllKeys];
    else
        [self installTapPrompting:NO];
    [self updateKeyboardOwnership];
    NSLog(@"keyboard capture %s (%@)%s", on ? "on" : "off", reason,
          on && !self.tap.active
              ? " -- system shortcuts stay with macOS (no Accessibility grant)"
              : "");
    [self noteCaptureState:reason];
}

/* The single-source rule in one line: while a live tap is forwarding for a
 * view whose capture is on, the responder methods send nothing. */
- (void)updateKeyboardOwnership
{
    self.view.tapOwnsKeyboard = self.tap.active && self.view.captureKeyboard;
}

/* Install the tap if this process may have one.  Called on every enable, so
 * a grant given while the viewer is running takes effect on the next toggle;
 * @mayPrompt asks macOS for its one-time dialog, at most once per run. */
- (BOOL)installTapPrompting:(BOOL)mayPrompt
{
    if (self.tap.active)
        return YES;
    /* The one path QA cannot reach any other way: TCC grants cannot be
     * revoked from inside the process, so this is how the no-Accessibility
     * behaviour gets tested on a machine that has the grant. */
    if (NSProcessInfo.processInfo.environment[@"VSM_NO_EVENT_TAP"]) {
        NSLog(@"VSM_NO_EVENT_TAP: pretending there is no Accessibility grant");
        return NO;
    }
    if (!self.tap) {
        self.tap = [[VsmEventTap alloc] init];
        self.tap.delegate = self;
    }
    if (![VsmEventTap isProcessTrusted:NO]) {
        if (mayPrompt && !self.promptedForAccessibility) {
            self.promptedForAccessibility = YES;
            (void)[VsmEventTap isProcessTrusted:YES];
        }
        NSLog(@"no Accessibility grant: Cmd-Space, Cmd-Tab and friends stay "
              @"with macOS (Input > Capture System Shortcuts to re-check)");
        return NO;
    }
    if (![self.tap install])
        return NO;
    [self updateKeyboardOwnership];
    return YES;
}

/* ----------------------------------------------------- the tap's decisions */

- (BOOL)eventTapShouldConsume:(NSEvent *)event
{
    if (![self captureActive]) {
        [self noteCaptureState:@"not capturing"];
        return NO;                    /* the rest of the system behaves */
    }
    [self noteCaptureState:@"key event"];

    switch (event.type) {
    case NSEventTypeFlagsChanged: return [self tapFlagsChanged:event];
    case NSEventTypeKeyDown:      return [self tapKeyDown:event];
    case NSEventTypeKeyUp:        return [self tapKeyUp:event];
    default:                      return NO;
    }
}

/* ⌃⌥ pressed together and released with nothing in between is the escape
 * chord (the T-0027 mouse-ungrab convention): the one keystroke that is
 * always handled locally.  It cannot be recognised until the release, so the
 * presses have already reached the guest by then -- which is the other half
 * of why firing it releases every key the guest holds. */
- (BOOL)tapFlagsChanged:(NSEvent *)event
{
    NSEventModifierFlags flags = event.modifierFlags;
    BOOL ctrl = (flags & NSEventModifierFlagControl) != 0;
    BOOL opt  = (flags & NSEventModifierFlagOption) != 0;

    if (ctrl && opt &&
        !(flags & (NSEventModifierFlagCommand | NSEventModifierFlagShift)))
        self.escapeArmed = YES;
    else if (self.escapeArmed && (flags & (NSEventModifierFlagCommand |
                                           NSEventModifierFlagShift)))
        self.escapeArmed = NO;        /* a third modifier: a real chord */

    if (self.escapeArmed && !ctrl && !opt) {
        self.escapeArmed = NO;
        [self setCapture:NO reason:@"ctrl-alt escape chord"];
        return YES;                   /* the chord itself is never forwarded */
    }
    /* Letting go of Cmd ends a hold, whichever half of it came up first. */
    if (!(flags & NSEventModifierFlagCommand))
        [self cancelQuitHold];
    [self.view handleFlagsChanged:event];
    return YES;
}

- (BOOL)tapKeyDown:(NSEvent *)event
{
    self.escapeArmed = NO;            /* a real keystroke, not the chord */

    switch ([self quitActionForKeyDown:event]) {
    case VSM_QUIT_NOW:
        [self quitNow];
        return YES;
    case VSM_QUIT_HOLD:
        /* Autorepeat must not restart the clock, or holding it forever would
         * never reach a second. */
        if (!event.isARepeat)
            [self startQuitHoldForKeyCode:event.keyCode];
        break;
    case VSM_QUIT_NONE:
        break;
    }
    [self.view sendKeyCode:event.keyCode down:YES];
    return YES;
}

- (BOOL)tapKeyUp:(NSEvent *)event
{
    /* Match the physical key that started the hold rather than a character:
     * it is the same keycode going up as came down on every layout. */
    if (self.quitHoldTimer && event.keyCode == self.quitHoldKeyCode)
        [self cancelQuitHold];
    [self.view sendKeyCode:event.keyCode down:NO];
    return YES;
}

/* ------------------------------------------------------------ Cmd-Q policy
 *
 * The single decision point, asked by both the event tap and the local key
 * monitor.  Captured, Cmd-Q belongs to the guest (Omarchy binds SUPER+Q to
 * "close window" and it is used constantly), and only holding it quits the
 * viewer -- Chrome's rule, and UTM's "captured goes to the guest".
 * Uncaptured it quits at once, from any state including a modal dialog,
 * which is the behaviour the monitor exists for.
 *
 * The hold needs the key-up that only the tap delivers -- a key equivalent
 * never produces one -- so with no tap a captured Cmd-Q simply goes to the
 * guest through -performKeyEquivalent: and quitting is the menu's job. */
- (VsmQuitAction)quitActionForKeyDown:(NSEvent *)event
{
    /* -characters, not -charactersIgnoringModifiers: with a non-Latin layout
     * active (Russian, Greek, ...) the latter is the layout's own letter --
     * "й" for the Q key -- and the chord would never be recognised.  Under
     * Cmd, -characters is what AppKit itself matches key equivalents against:
     * the ASCII-capable layout's letter, which is "q" on any keyboard whose Q
     * key is where Q is, and follows the key on the ones where it is not. */
    /* Only the four modifiers a user can mean: Cmd set, nothing else of
     * consequence.  Matching the whole device-independent field instead
     * fails on Caps Lock, and on the bits macOS itself adds to an event that
     * has been through the tap chain (0x20000000 on a posted event). */
    const NSEventModifierFlags interesting =
        NSEventModifierFlagCommand | NSEventModifierFlagShift |
        NSEventModifierFlagControl | NSEventModifierFlagOption;

    if ((event.modifierFlags & interesting) != NSEventModifierFlagCommand ||
        [event.characters caseInsensitiveCompare:@"q"] != NSOrderedSame)
        return VSM_QUIT_NONE;
    if (![self captureActive])
        return VSM_QUIT_NOW;
    return self.tap.active ? VSM_QUIT_HOLD : VSM_QUIT_NONE;
}

- (void)quitNow
{
    [self.view releaseAllKeys];
    [NSApp terminate:nil];
}

- (void)startQuitHoldForKeyCode:(unsigned short)keyCode
{
    if (self.quitHoldTimer)
        return;
    self.quitHoldKeyCode = keyCode;
    [self showQuitHUD];
    /* Scheduled by hand in the common modes: a hold has to keep counting
     * while a menu is tracking or a sheet is up, not just in the default
     * run loop mode. */
    self.quitHoldTimer = [NSTimer timerWithTimeInterval:VSM_QUIT_HOLD_SECONDS
                                                 target:self
                                               selector:@selector(quitHoldFired:)
                                               userInfo:nil
                                                repeats:NO];
    [NSRunLoop.mainRunLoop addTimer:self.quitHoldTimer
                            forMode:NSRunLoopCommonModes];
}

- (void)cancelQuitHold
{
    if (!self.quitHoldTimer)
        return;
    [self.quitHoldTimer invalidate];
    self.quitHoldTimer = nil;
    [self hideQuitHUD];
}

- (void)quitHoldFired:(NSTimer *)timer
{
    (void)timer;
    self.quitHoldTimer = nil;
    [self hideQuitHUD];
    NSLog(@"Cmd-Q held for %.0f s: quitting", VSM_QUIT_HOLD_SECONDS);
    /* The press was forwarded when the key went down and the guest will
     * never see the matching key-up, because the app is about to go away.
     * Send it before the session is torn down so nothing sticks. */
    [self.view sendKeyCode:self.quitHoldKeyCode down:NO];
    [self quitNow];
}

/* A borderless panel rather than an alert: it must appear over a fullscreen
 * guest in its own Space, must not take focus (the key is still down and its
 * release has to reach the same responder), and must vanish the instant the
 * key comes up. */
- (void)showQuitHUD
{
    NSRect frame;

    if (!self.quitHUD) {
        NSPanel *panel = [[VsmHUDPanel alloc]
            initWithContentRect:NSMakeRect(0, 0, 260, 68)
                      styleMask:(NSWindowStyleMaskBorderless |
                                 NSWindowStyleMaskNonactivatingPanel)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        NSTextField *label = [NSTextField labelWithString:@"Hold ⌘Q to Quit"];
        NSView *content = panel.contentView;

        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.level = NSStatusWindowLevel;
        panel.ignoresMouseEvents = YES;
        panel.hidesOnDeactivate = NO;
        panel.releasedWhenClosed = NO;
        panel.becomesKeyOnlyIfNeeded = YES;
        panel.collectionBehavior = (NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorIgnoresCycle);
        content.wantsLayer = YES;
        content.layer.backgroundColor =
            [NSColor colorWithWhite:0.0 alpha:0.78].CGColor;
        content.layer.cornerRadius = 14.0;
        label.font = [NSFont boldSystemFontOfSize:19];
        label.textColor = NSColor.whiteColor;
        label.alignment = NSTextAlignmentCenter;
        label.frame = NSMakeRect(0, 22, 260, 26);
        [content addSubview:label];
        self.quitHUD = panel;
    }
    frame = self.window ? self.window.frame
                        : NSScreen.mainScreen.frame;
    [self.quitHUD setFrameOrigin:
        NSMakePoint(NSMidX(frame) - self.quitHUD.frame.size.width / 2,
                    NSMidY(frame) - self.quitHUD.frame.size.height / 2)];
    [self.quitHUD orderFront:nil];
    NSLog(@"Cmd-Q down while captured: forwarded to the guest, "
          @"hold %.0f s to quit", VSM_QUIT_HOLD_SECONDS);
}

- (void)hideQuitHUD
{
    [self.quitHUD orderOut:nil];
}

- (void)sendKeyChord:(NSMenuItem *)item
{
    NSLog(@"send key: %@", item.title);
    [self.view sendChord:item.representedObject];
}

/* One guest pixel per physical display pixel: on a 2x Retina panel the window
 * is half as many points wide as the guest is pixels, and the compositor does
 * no resampling.  This is the size the window is given on connect, and the
 * size the View menu restores. */
- (void)resizeToGuestPixels
{
    CGFloat scale = self.window.backingScaleFactor ?: 1.0;

    if (self.view.guestWidth <= 0 || self.view.guestHeight <= 0)
        return;
    [self.window setContentSize:NSMakeSize(self.view.guestWidth / scale,
                                           self.view.guestHeight / scale)];
}

/* Log what the window currently occupies.  The second rect is in the
 * top-left-origin space screencapture(1) takes for -R, so a QA run can grab
 * exactly this window (and nothing else on the desktop) from the log. */
- (void)logWindowGeometry:(NSString *)what
{
    NSRect frame = self.window.frame;
    NSRect content = [self.window contentRectForFrameRect:frame];
    CGFloat screenHeight = NSScreen.screens.firstObject.frame.size.height;

    NSLog(@"%@: content %.0fx%.0f pt, guest %dx%d, backing scale %.1f, "
          @"fullscreen %@, screencapture -R %.0f,%.0f,%.0f,%.0f",
          what, content.size.width, content.size.height,
          self.view.guestWidth, self.view.guestHeight,
          self.window.backingScaleFactor, [self isFullScreen] ? @"yes" : @"no",
          frame.origin.x, screenHeight - NSMaxY(frame),
          frame.size.width, frame.size.height);
}

- (void)actualSize:(id)sender
{
    [self resizeToGuestPixels];
    [self logWindowGeometry:@"actual size"];
}

/* AppKit disables the main menu for the duration of a modal session, so the
 * Quit item alone would leave the user stuck behind the password prompt or
 * the disconnect alert with no way out but the Dock.  A local key monitor
 * sees the event before it reaches the responder chain, in the modal run loop
 * as well as the normal one, so Cmd-Q means quit in every state that is not
 * the guest's.
 *
 * Which states those are is -quitActionForKeyDown:'s answer, not this
 * block's: the monitor and the event tap ask the same question, and only
 * VSM_QUIT_NOW is actionable here (an event the tap wanted was consumed and
 * never arrives, and forwarding is the responder chain's job). */
- (void)installQuitMonitor
{
    __weak VsmAppDelegate *weakSelf = self;

    self.quitMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent *(NSEvent *event) {
        VsmAppDelegate *self = weakSelf;

        if ([self quitActionForKeyDown:event] == VSM_QUIT_NOW) {
            [self quitNow];
            return nil;
        }
        return event;
    }];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self buildMenu];
    [self installQuitMonitor];
    [self installDumpSignalHandler];
    /* Capture defaults on, so this launch is the first enable: ask for the
     * Accessibility grant once here and never again this run.  Without it
     * everything below still works, minus the system chords. */
    [self installTapPrompting:YES];
    [self updateKeyboardOwnership];

    self.didFinishLaunching = YES;
    /* A URL or .vv file that started the app was handled before this point;
     * an unopenable one left its message here. */
    if (self.pendingOpenError) {
        NSString *message = self.pendingOpenError;

        self.pendingOpenError = nil;
        [self showOpenAlert:@"Cannot open this connection" informative:message];
    }

    /* A URI on argv -- or one an open handler just recorded -- means "connect
     * to this now", exactly as before the connect window existed; without one
     * the user is asked. */
    if (self.uri)
        [self connect];
    else
        [self showConnectWindow];
}

/* ------------------------------------------------------------ session state
 *
 * The app has three states and moves between them only here:
 *
 *   connect window  --Connect-->  connected  --disconnect--> modal alert
 *          ^                          ^                          |
 *          +------- Close ------------+------ Reconnect ---------+
 *
 * A session is never reused: reconnecting (and retrying with a password)
 * tears the VsmSpice down and builds a fresh one, which is also what
 * spice-client-glib expects -- a SpiceSession that has errored out is done.
 */

- (void)showConnectWindow
{
    if (!self.connectWindow) {
        __weak VsmAppDelegate *weakSelf = self;
        self.connectWindow = [[VsmConnectWindowController alloc]
            initWithHandler:^(NSString *uri) { [weakSelf connectToURI:uri]; }];
    }
    [self.connectWindow showWithURI:self.uri];
}

- (void)connectToURI:(NSString *)uri
{
    /* Remember the URI, never the password. */
    [NSUserDefaults.standardUserDefaults setObject:uri forKey:VsmLastURIKey];
    self.uri = uri;
    [self.connectWindow hide];
    [self connect];
}

/* --------------------------------------------------- open URLs and files
 *
 * Both LaunchServices entry points -- a spice:// URL and a double-clicked
 * .vv file -- end here, and both can fire before -applicationDidFinishLaunching:
 * (that is how Finder starts the app in the first place).  So neither handler
 * connects directly: they record what was asked for and either act now, if
 * the app is already up, or let the launch do it.
 */

/* One-button "no" for an open request that cannot be honoured right now. */
- (void)showOpenAlert:(NSString *)message informative:(NSString *)informative
{
    NSAlert *alert = [[NSAlert alloc] init];

    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = message;
    if (informative)
        alert.informativeText = informative;
    [alert addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [alert runModal];
}

/* Report @message now if the app is running, or at the end of launch if the
 * request arrived before there was a UI to put an alert in front of. */
- (void)reportOpenFailure:(NSString *)message
{
    if (!self.didFinishLaunching) {
        self.pendingOpenError = message;
        return;
    }
    [self showOpenAlert:@"Cannot open this connection" informative:message];
}

/* Connect to @uri, optionally with @password.  A session already on screen
 * wins: this viewer shows one display, and silently dropping the running one
 * because a stale .vv was double-clicked would be the wrong trade. */
- (void)openConnectionURI:(NSString *)uri password:(NSString *)password
{
    if (self.spice) {
        [self showOpenAlert:@"Already connected"
                informative:@"Disconnect the current session before opening "
                            @"another connection."];
        return;
    }

    self.uri = uri;
    self.password = password;
    [NSUserDefaults.standardUserDefaults setObject:uri forKey:VsmLastURIKey];

    /* Before launch there is no window and no menu yet; the connect happens
     * at the end of -applicationDidFinishLaunching:, which reads self.uri. */
    if (!self.didFinishLaunching)
        return;
    [self.connectWindow hide];
    [self connect];
}

/* Read a .vv connection file and connect to what it describes. */
- (void)openVvFile:(NSString *)path
{
    g_autoptr(GError) error = NULL;
    VsmVvFile *vv;

    vv = vsm_vv_parse(path.fileSystemRepresentation, &error);
    if (!vv) {
        /* The path is part of the message: a .vv that fails to load usually
         * fails because it is not the file the user thought it was. */
        [self reportOpenFailure:[NSString stringWithFormat:@"%@\n\n%s",
                                          path, error->message]];
        return;
    }

    /* Only once the file has been accepted: a file the user still needs
     * because we refused to open it must not disappear. */
    if (vv->delete_file)
        vsm_vv_delete(path.fileSystemRepresentation);

    [self openConnectionURI:@(vv->uri)
                   password:vv->password ? @(vv->password) : nil];
    vsm_vv_free(vv);
}

/* A spice:// or spice+tls:// URL.  The scheme is checked here rather than
 * left to spice-client-glib: a URL of some other scheme is a LaunchServices
 * misroute, and "connection failed" would be a misleading way to say so. */
- (void)openSpiceURL:(NSURL *)url
{
    NSString *scheme = url.scheme.lowercaseString;

    if (![scheme isEqualToString:@"spice"] &&
        ![scheme isEqualToString:@"spice+tls"]) {
        [self reportOpenFailure:
            [NSString stringWithFormat:@"“%@” is not a SPICE address. "
                                       @"This viewer opens spice:// and "
                                       @"spice+tls:// connections.",
                                       url.absoluteString]];
        return;
    }
    [self openConnectionURI:url.absoluteString password:nil];
}

/* Everything LaunchServices opens, both at launch and while running: URLs
 * from a browser and files from Finder alike.  Since macOS 10.13 a delegate
 * that implements this method receives file opens here as file:// URLs and
 * -application:openFile: is never called, so the two have to be told apart
 * here -- handing a file:// URL to the session is how you get "connection
 * failed" for a perfectly good .vv file.
 *
 * macOS can hand over several at once; this viewer has one display, so the
 * first one is opened and the rest hit the already-connected alert. */
- (void)application:(NSApplication *)app openURLs:(NSArray<NSURL *> *)urls
{
    (void)app;
    for (NSURL *url in urls) {
        if (url.isFileURL)
            [self openVvFile:url.path];
        else
            [self openSpiceURL:url];
    }
}

/* The other document-open path.  AppKit does not use it for Finder opens
 * while -application:openURLs: exists, but it is still how a *bundled* app
 * receives a command-line argument: argv[1] arrives here as a "file to open",
 * even when it is a spice:// URL.  So the argument is classified before it is
 * used -- feeding a URL to the .vv parser is how a perfectly good command
 * line turns into "No such file or directory".
 *
 * YES either way: the failure has already been reported in our own words, and
 * returning NO only adds a second, vaguer Finder alert on top of it. */
- (BOOL)application:(NSApplication *)app openFile:(NSString *)filename
{
    NSURL *url = [NSURL URLWithString:filename];

    (void)app;
    if (url.scheme && !url.isFileURL)
        [self openSpiceURL:url];
    else
        [self openVvFile:url.isFileURL ? url.path : filename];
    return YES;
}

/* Build the session for self.uri and put the viewer window on screen. */
- (void)connect
{
    if (!self.window)
        [self createViewerWindow];
    self.window.title = self.uri;

    self.spice = vsm_spice_new(self.uri.UTF8String, &vsm_callbacks,
                               (__bridge void *)self);
    if (self.password)
        vsm_spice_set_password(self.spice, self.password.UTF8String);
    self.view.spice = self.spice;

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.view];
    [NSApp activateIgnoringOtherApps:YES];
    [self updateKeyboardOwnership];

    vsm_spice_start(self.spice);
}

/* Release the guest's keys, stop the GLib thread and drop the session.  Safe
 * with no session; leaves the viewer window alone. */
- (void)teardownSession
{
    VsmSpice *spice = self.spice;

    if (!spice)
        return;
    [self.view releaseAllKeys];
    self.spice = NULL;
    self.view.spice = NULL;
    [self cancelQuitHold];
    [self noteCaptureSuspendedBy:@"session disconnected"];
    vsm_spice_stop(spice);
    vsm_spice_free(spice);
}

/* The session ended.  Tear it down BEFORE any dialog goes up: a modal run
 * loop pumps the main queue, so leaving a dead session's callbacks live
 * behind an alert would let them run against a half-torn-down view. */
- (void)disconnectedWithReason:(const char *)reason authFailed:(BOOL)authFailed
{
    VsmDisconnectChoice choice;

    if (!self.spice || self.handlingDisconnect)
        return;                       /* a sibling channel already reported */
    self.handlingDisconnect = YES;
    [self teardownSession];
    [self.window orderOut:nil];

    if (authFailed) {
        NSString *password = vsm_prompt_password(self.uri);
        self.handlingDisconnect = NO;
        if (!password) {
            [self showConnectWindow];
            return;
        }
        self.password = password;
        [self connect];
        return;
    }

    choice = vsm_prompt_disconnect(self.uri, reason);
    self.handlingDisconnect = NO;
    if (choice == VSM_DISCONNECT_RECONNECT)
        [self connect];
    else
        [self showConnectWindow];
}

/* ------------------------------------------------------- the viewer window */

- (void)createViewerWindow
{
    NSRect frame = NSMakeRect(0, 0, 800, 600);

    self.window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                             NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    self.window.delegate = self;
    self.window.acceptsMouseMovedEvents = YES;
    self.window.releasedWhenClosed = NO;
    /* Native macOS fullscreen (its own Space, ctrl-Cmd-F, the green button).
     * The window background matches the view's so the bars either side of an
     * aspect-fitted guest image are black rather than window grey. */
    self.window.collectionBehavior |= NSWindowCollectionBehaviorFullScreenPrimary;
    self.window.backgroundColor = NSColor.blackColor;

    self.view = [[VsmView alloc] initWithFrame:frame];
    self.view.spice = self.spice;
    self.window.contentView = self.view;
    self.view.layer.contentsScale = self.window.backingScaleFactor;

    [self.window center];
}

/* SIGUSR1 writes the guest framebuffer to $VSM_DUMP_DIR/frame-N.png.  This
 * is the only way to see what the client is displaying on a machine whose
 * login session is locked, where screencapture(1) returns the lock screen. */
- (void)installDumpSignalHandler
{
    NSString *dir = NSProcessInfo.processInfo.environment[@"VSM_DUMP_DIR"];
    if (!dir)
        return;

    signal(SIGUSR1, SIG_IGN);
    dispatch_source_t src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,
                                                   SIGUSR1, 0,
                                                   dispatch_get_main_queue());
    __block int seq = 0;
    dispatch_source_set_event_handler(src, ^{
        NSString *path;

        if (!self.window || !self.spice) {
            NSLog(@"no session on screen; nothing to dump");
            return;
        }
        path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"frame-%d.png", ++seq]];
        [self logWindowGeometry:@"window"];
        vsm_dump_surface(self.spice, path);
    });
    dispatch_resume(src);
    self.dumpSource = src;
    NSLog(@"SIGUSR1 will dump frames to %@", dir);
}

/* Lock the window's proportions to the guest's, so a user drag cannot letter-
 * box the image.  Not while fullscreen: an aspect-ratio constraint and a
 * screen-sized frame contradict each other, and -windowDidExitFullScreen:
 * puts the constraint back afterwards. */
- (void)applyGuestAspectRatio
{
    if (self.view.guestWidth <= 0 || self.view.guestHeight <= 0 ||
        [self isFullScreen])
        return;
    self.window.contentAspectRatio = NSMakeSize(self.view.guestWidth,
                                                self.view.guestHeight);
}

- (void)windowWillEnterFullScreen:(NSNotification *)note
{
    if (note.object != self.window)
        return;
    /* Setting resize increments is the documented way to drop an aspect-ratio
     * constraint; leaving it in place makes AppKit refuse to grow the window
     * to the full screen.  The guest image stays proportional anyway -- the
     * layer's kCAGravityResizeAspect letterboxes it against the black view. */
    self.window.resizeIncrements = NSMakeSize(1, 1);
}

- (void)windowDidEnterFullScreen:(NSNotification *)note
{
    if (note.object != self.window)
        return;
    [self logWindowGeometry:@"entered fullscreen"];
}

- (void)windowDidExitFullScreen:(NSNotification *)note
{
    if (note.object != self.window)
        return;
    [self applyGuestAspectRatio];
    [self logWindowGeometry:@"left fullscreen"];
}

/* A guest changes video mode by destroying and recreating its primary
 * surface, so this runs again mid-session with new dimensions: everything
 * derived from the old size -- the IOSurface the layer samples, the
 * aspect-ratio lock, the window size -- has to be recomputed here. */
- (void)primaryCreatedWidth:(int)width height:(int)height
{
    CGFloat scale = self.window.backingScaleFactor ?: 1.0;
    BOOL modeChange = (self.view.guestWidth > 0 &&
                       (width != self.view.guestWidth ||
                        height != self.view.guestHeight));

    self.view.guestWidth = width;
    self.view.guestHeight = height;
    /* In fullscreen the frame belongs to the screen, so only the letterboxing
     * changes and the layer's aspect-fit gravity has already done that. */
    if (![self isFullScreen]) {
        [self resizeToGuestPixels];
        [self applyGuestAspectRatio];
    }
    [self.view refreshSurface];
    NSLog(@"primary surface %dx%d (backing scale %.1f)%s%s", width, height, scale,
          modeChange ? " [guest resolution change]" : "",
          [self isFullScreen] ? " [fullscreen: refit only]" : "");

    if (!self.cursorSelftestDone &&
        NSProcessInfo.processInfo.environment[@"VSM_CURSOR_SELFTEST"]) {
        self.cursorSelftestDone = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            vsm_run_cursor_selftest(self.view);
        });
    }

    if (!self.sendkeySelftestDone &&
        NSProcessInfo.processInfo.environment[@"VSM_SENDKEY_SELFTEST"]) {
        self.sendkeySelftestDone = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            vsm_run_sendkey_selftest(self.view);
        });
    }

    if (!self.selftestDone &&
        NSProcessInfo.processInfo.environment[@"VSM_SELFTEST"]) {
        self.selftestDone = YES;
        /* Give the guest a moment to settle, then replay the script. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                       dispatch_get_main_queue(), ^{
            vsm_run_input_selftest(self.view, self.window);
            if (NSProcessInfo.processInfo.environment[@"VSM_SELFTEST_QUIT"]) {
                /* Same selector the Cmd-Q menu item sends, so this exercises
                 * the real quit path: release-all-keys, disconnect, join. */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC),
                               dispatch_get_main_queue(), ^{
                    NSLog(@"selftest: terminating via the Cmd-Q action");
                    [NSApp terminate:nil];
                });
            }
        });
    }
}

/* Auto-suspend: capture follows focus.  -captureActive already reads these
 * two states, so the tap stops consuming by itself the moment either goes
 * false; what is left to do here is release the guest's keys, drop any hold
 * in progress and put the edge in the log. */
- (void)windowDidResignKey:(NSNotification *)note
{
    (void)note;
    [self.view releaseAllKeys];
    [self cancelQuitHold];
    self.escapeArmed = NO;
    [self noteCaptureSuspendedBy:@"viewer window resigned key"];
}

- (void)applicationDidResignActive:(NSNotification *)note
{
    (void)note;
    [self.view releaseAllKeys];
    [self cancelQuitHold];
    self.escapeArmed = NO;
    [self noteCaptureSuspendedBy:@"application deactivated"];
}

- (void)applicationDidBecomeActive:(NSNotification *)note
{
    (void)note;
    [self noteCaptureState:@"app activated"];
}

/* NO, because the window the user closes is usually on its way to being
 * replaced: closing the viewer hands them back to the connect window, and the
 * connect window quits the app explicitly when it is closed. */
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return NO; }

/* Closing the viewer window ends the session but not the process.  The
 * teardown path orders the window out rather than closing it, so this only
 * fires for a real user click on the close button. */
- (void)windowWillClose:(NSNotification *)note
{
    if (note.object != self.window)
        return;
    [self teardownSession];
    [self showConnectWindow];
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    [self teardownSession];
    NSLog(@"disconnected cleanly");
}

@end

/* -------------------------------------------------------------- C glue */

static VsmAppDelegate *g_delegate;

static void cb_primary_create(void *user, int width, int height)
{
    [(__bridge VsmAppDelegate *)user primaryCreatedWidth:width height:height];
}

static void cb_damaged(void *user, int x, int y, int w, int h)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    if (vsm_trace)
        NSLog(@"damage %d,%d %dx%d", x, y, w, h);
    [self.view refreshSurface];
}

/* Build an NSCursor from the guest's RGBA bytes.  The shape is treated as
 * 1x points: a guest cursor is authored in guest pixels and the view shows
 * guest pixels, so one cursor pixel is one point.  On a 2x panel that means
 * the shape is drawn at 2x2 physical pixels per cursor pixel -- softer than
 * a native cursor, but the correct size next to the guest content, which is
 * what a pointer has to be.  A Retina-aware (2x) cursor would need the guest
 * to author one, and SPICE has no way to ask for it. */
NSCursor *vsm_cursor_from_rgba(int width, int height,
                               int hot_x, int hot_y,
                               const uint8_t *rgba)
{
    NSBitmapImageRep *rep;
    NSImage *image;

    /* bitmapFormat 0 = premultiplied alpha, RGBA byte order -- exactly what
     * channel-cursor.c produces (it byte-swaps its BGRA words for us). */
    rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:width
                      pixelsHigh:height
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                    bitmapFormat:0
                     bytesPerRow:width * 4
                    bitsPerPixel:32];
    if (!rep)
        return nil;
    memcpy(rep.bitmapData, rgba, (size_t)width * (size_t)height * 4);

    image = [[NSImage alloc] initWithSize:NSMakeSize(width, height)];
    [image addRepresentation:rep];

    /* The hotspot is in the image's own (top-left origin) coordinates, which
     * is how SPICE expresses it too. */
    return [[NSCursor alloc] initWithImage:image
                                   hotSpot:NSMakePoint(hot_x, hot_y)];
}

static void cb_cursor_define(void *user, int width, int height,
                             int hot_x, int hot_y, const uint8_t *rgba)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    NSCursor *cursor;

    if (vsm_trace)
        NSLog(@"cursor-define %dx%d hotspot %d,%d", width, height, hot_x, hot_y);
    cursor = vsm_cursor_from_rgba(width, height, hot_x, hot_y, rgba);
    /* vsm-spice.c handed the copy over; NSBitmapImageRep took its own. */
    free((void *)rgba);
    if (cursor)
        [self.view setGuestCursor:cursor];
}

static void cb_cursor_hide(void *user)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    if (vsm_trace)
        NSLog(@"cursor-hide");
    [self.view hideGuestCursor];
}

static void cb_cursor_reset(void *user)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    if (vsm_trace)
        NSLog(@"cursor-reset");
    [self.view resetGuestCursor];
}

static void cb_title(void *user, const char *title)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;
    self.window.title = @(title);
}

static void cb_status(void *user, const char *status)
{
    (void)user;
    NSLog(@"%s", status);
}

static void cb_disconnected(void *user, const char *reason, int auth_failed)
{
    VsmAppDelegate *self = (__bridge VsmAppDelegate *)user;

    NSLog(@"disconnected: %s", reason);
    [self disconnectedWithReason:reason authFailed:auth_failed ? YES : NO];
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        const char *uri = NULL;
        int i;

        /* LaunchServices can still append a -psn_0_... process serial number
         * to an app bundle it starts; it is not a URI and must not turn a
         * Finder launch into a usage error. */
        for (i = 1; i < argc; i++) {
            if (g_str_has_prefix(argv[i], "-psn_"))
                continue;
            if (uri) {
                fprintf(stderr, "usage: %s [spice://HOST:PORT]\n", argv[0]);
                return 2;
            }
            uri = argv[i];
        }
        vsm_trace = getenv("VSM_TRACE") && *getenv("VSM_TRACE") == '1';

        [NSApplication sharedApplication];
        NSApp.activationPolicy = NSApplicationActivationPolicyRegular;

        g_delegate = [[VsmAppDelegate alloc] init];
        /* No URI: applicationDidFinishLaunching opens the connect window --
         * unless a spice:// URL or a .vv file arrives before it runs. */
        if (uri)
            g_delegate.uri = @(uri);
        NSApp.delegate = g_delegate;

        [NSApp run];
    }
    return 0;
}
