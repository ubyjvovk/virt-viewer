/*
 * vsm-connect.m: connect window, password prompt and disconnect alert.
 *
 * Built in code rather than from a nib: the whole UI is three controls and a
 * two-button alert, and a nib would drag an .app bundle layout into what is
 * still a single self-contained binary.
 */
#import "vsm-connect.h"

NSString *const VsmLastURIKey = @"VsmLastURI";

/* Geometry of the connect window, in points. */
enum {
    VSM_CONNECT_WIDTH  = 440,
    VSM_CONNECT_HEIGHT = 108,
    VSM_CONNECT_MARGIN = 20,
};

@implementation VsmConnectWindowController {
    NSWindow    *_window;
    NSTextField *_field;
    void (^_handler)(NSString *uri);
}

- (instancetype)initWithHandler:(void (^)(NSString *uri))handler
{
    self = [super init];
    if (!self)
        return nil;

    _handler = [handler copy];

    NSRect content = NSMakeRect(0, 0, VSM_CONNECT_WIDTH, VSM_CONNECT_HEIGHT);
    CGFloat inner = VSM_CONNECT_WIDTH - 2 * VSM_CONNECT_MARGIN;

    _window = [[NSWindow alloc]
        initWithContentRect:content
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _window.title = @"Connect";
    _window.delegate = self;
    _window.releasedWhenClosed = NO;

    NSTextField *label =
        [NSTextField labelWithString:@"Connect to a SPICE display:"];
    label.frame = NSMakeRect(VSM_CONNECT_MARGIN, 70, inner, 17);
    [_window.contentView addSubview:label];

    _field = [[NSTextField alloc]
        initWithFrame:NSMakeRect(VSM_CONNECT_MARGIN, 42, inner, 24)];
    _field.placeholderString = @"spice://host:port";
    /* Return in the field is the same gesture as clicking Connect; AppKit
     * routes it to the window's default button, so no action is set here. */
    [_window.contentView addSubview:_field];

    NSButton *connect = [NSButton buttonWithTitle:@"Connect"
                                           target:self
                                           action:@selector(connect:)];
    connect.frame = NSMakeRect(VSM_CONNECT_WIDTH - VSM_CONNECT_MARGIN - 100, 6,
                               100, 32);
    connect.keyEquivalent = @"\r";
    [_window.contentView addSubview:connect];

    return self;
}

- (void)showWithURI:(NSString *)uri
{
    NSString *remembered =
        [NSUserDefaults.standardUserDefaults stringForKey:VsmLastURIKey];

    _field.stringValue = uri ?: (remembered ?: @"");
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [_window makeFirstResponder:_field];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)hide
{
    [_window orderOut:nil];
}

- (void)connect:(id)sender
{
    NSString *uri = [_field.stringValue
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];

    (void)sender;
    if (!uri.length) {
        NSBeep();
        return;
    }
    if (_handler)
        _handler(uri);
}

/* The connect window is shown exactly when there is no session on screen, so
 * closing it is the user saying "I am done" -- there would otherwise be no
 * window left to quit from. */
- (void)windowWillClose:(NSNotification *)note
{
    (void)note;
    [NSApp terminate:nil];
}

@end

/* ---------------------------------------------------------------- dialogs */

NSString *vsm_prompt_password(NSString *uri)
{
    NSAlert *alert = [[NSAlert alloc] init];
    NSSecureTextField *field;
    NSString *password;

    alert.messageText = @"Authentication required";
    alert.informativeText = [NSString stringWithFormat:@"Password for %@", uri];
    [alert addButtonWithTitle:@"Connect"];
    [alert addButtonWithTitle:@"Cancel"];

    field = [[NSSecureTextField alloc]
        initWithFrame:NSMakeRect(0, 0, 260, 24)];
    alert.accessoryView = field;
    /* layout before setting the first responder: the accessory view is not in
     * the alert's window until the alert has laid itself out. */
    [alert layout];
    [alert.window makeFirstResponder:field];

    if ([alert runModal] != NSAlertFirstButtonReturn)
        return nil;
    password = field.stringValue;
    return password.length ? password : nil;
}

VsmDisconnectChoice vsm_prompt_disconnect(NSString *uri, const char *reason)
{
    NSAlert *alert = [[NSAlert alloc] init];

    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:@"Disconnected from %@", uri];
    alert.informativeText = @(reason ?: "the connection ended");
    [alert addButtonWithTitle:@"Reconnect"];
    [alert addButtonWithTitle:@"Close"];

    return [alert runModal] == NSAlertFirstButtonReturn
        ? VSM_DISCONNECT_RECONNECT : VSM_DISCONNECT_CLOSE;
}
