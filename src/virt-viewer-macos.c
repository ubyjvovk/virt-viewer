/*
 * Virt Viewer: A virtual machine console viewer
 *
 * macOS (Cocoa) desktop integration.
 *
 * This file is compiled only when gtk-mac-integration was found, which meson
 * only ever looks for on darwin, so everything here is macOS-only by
 * construction. Call sites in the portable code are guarded with
 * #ifdef HAVE_GTK_MAC_INTEGRATION.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
 */

#include <config.h>

#include <glib/gi18n.h>
/* Unqualified: gtk-mac-integration-gtk3.pc puts ${includedir}/gtkmacintegration
 * itself on the include path, not ${includedir}. */
#include <gtkosxapplication.h>

#include "virt-viewer-macos.h"

/* Where each GtkWindow keeps the (never displayed) GtkMenuBar that
 * gtk-mac-integration mirrors into the Cocoa menu bar. */
#define VIRT_VIEWER_MACOS_MENUBAR_KEY "virt-viewer-macos-menubar"
/* The menu bar currently mirrored into Cocoa, so a window that regains focus
 * repeatedly does not reinstall the same one. */
static GtkWidget *virt_viewer_macos_current_menubar;
/* Where the VirtViewerApp keeps the app-menu About item alive. */
#define VIRT_VIEWER_MACOS_ABOUT_KEY "virt-viewer-macos-about-item"
/* Set by virt_viewer_macos_set_open_uri_func(); NULL in binaries that do not
 * take a connection URI on the command line (virt-viewer). */
static VirtViewerMacosOpenUriFunc virt_viewer_macos_open_uri_func;

static gboolean
virt_viewer_macos_block_termination(GtkosxApplication *osxapp G_GNUC_UNUSED,
                                    gpointer opaque)
{
    VirtViewerApp *app = VIRT_VIEWER_APP(opaque);

    virt_viewer_app_maybe_quit(app, virt_viewer_app_get_main_window(app));

    /* Always veto Cocoa's own termination: virt_viewer_app_maybe_quit() may
     * put up a modal confirmation, and when the user confirms it calls
     * g_application_quit() which unwinds the GTK main loop for us. Letting
     * Cocoa terminate instead would skip that shutdown path entirely. */
    return TRUE;
}

static void
virt_viewer_macos_did_become_active(GtkosxApplication *osxapp G_GNUC_UNUSED,
                                    gpointer opaque)
{
    VirtViewerApp *app = VIRT_VIEWER_APP(opaque);
    GList *w;

    /* Dock "reopen": restore any window the user minimized. Deliberately no
     * gtk_window_present() here — with several displays open that would move
     * the focus off whichever window the user actually clicked. */
    for (w = virt_viewer_app_get_windows(app); w != NULL; w = w->next) {
        GtkWindow *window = virt_viewer_window_get_window(VIRT_VIEWER_WINDOW(w->data));

        if (gtk_widget_get_visible(GTK_WIDGET(window)))
            gtk_window_deiconify(window);
    }
}

static void
virt_viewer_macos_about_activate(GtkMenuItem *item G_GNUC_UNUSED,
                                 gpointer opaque)
{
    VirtViewerApp *app = VIRT_VIEWER_APP(opaque);
    VirtViewerWindow *window = virt_viewer_app_get_main_window(app);

    if (window != NULL)
        virt_viewer_window_show_about(window);
}

static gboolean
virt_viewer_macos_open_file(GtkosxApplication *osxapp G_GNUC_UNUSED,
                            gchar *target,
                            gpointer opaque)
{
    VirtViewerApp *app = VIRT_VIEWER_APP(opaque);
    g_autofree gchar *uri = NULL;

    g_debug("macOS asked the application to open %s", target ? target : "(null)");

    if (virt_viewer_macos_open_uri_func == NULL || target == NULL || *target == '\0')
        return FALSE;

    /* Cocoa routes both document opens (a double-clicked .vv file) and
     * URL-scheme opens (spice://, vnc://) through the same delegate method,
     * and gtk-mac-integration forwards the NSURL's absoluteString — so a file
     * arrives here as a percent-encoded file:// URI. Turn that back into a
     * local path; everything else is a connection URI and is passed through
     * untouched. */
    if (g_str_has_prefix(target, "file://")) {
        g_autoptr(GFile) file = g_file_new_for_uri(target);

        uri = g_file_get_path(file);
        if (uri == NULL) {
            g_warning("Cannot open remote location %s", target);
            return FALSE;
        }
    } else {
        uri = g_strdup(target);
    }

    virt_viewer_macos_open_uri_func(app, uri);

    return TRUE;
}

/**
 * virt_viewer_macos_set_open_uri_func:
 * @func: (nullable): the handler, or %NULL to remove the current one
 *
 * Install the handler run when macOS asks the application to open a URL or a
 * document. Must be called before virt_viewer_macos_init(), which is where the
 * Cocoa side is hooked up. There is one Cocoa application per process, so the
 * handler is process-wide.
 */
void
virt_viewer_macos_set_open_uri_func(VirtViewerMacosOpenUriFunc func)
{
    virt_viewer_macos_open_uri_func = func;
}

/**
 * virt_viewer_macos_spawn_uri:
 * @uri: a connection URI or a path to a `.vv` file
 * @error: (nullable): return location for a #GError
 *
 * Start a second copy of the running application bundle on @uri, as if it had
 * been passed on the command line. A #VirtViewerApp drives exactly one
 * connection, so this is what a request to open a second URI turns into —
 * matching Linux, where the application is %G_APPLICATION_NON_UNIQUE and every
 * `remote-viewer URI` is its own process.
 *
 * Returns: %TRUE if the process was started
 */
gboolean
virt_viewer_macos_spawn_uri(const gchar *uri, GError **error)
{
    g_autofree gchar *executable = gtkosx_application_get_executable_path();
    gchar *argv[3];

    g_return_val_if_fail(uri != NULL, FALSE);

    if (executable == NULL) {
        g_set_error_literal(error, G_SPAWN_ERROR, G_SPAWN_ERROR_FAILED,
                            _("Not running from an application bundle"));
        return FALSE;
    }

    argv[0] = executable;
    argv[1] = (gchar *)uri;
    argv[2] = NULL;

    return g_spawn_async(NULL, argv, NULL, G_SPAWN_DEFAULT, NULL, NULL, NULL, error);
}

/**
 * virt_viewer_macos_init:
 * @app: the #VirtViewerApp
 *
 * Set up the macOS application-wide integration: Quartz accelerators (so GTK
 * renders accelerators as ⌘ combinations in the Cocoa menu bar), the app menu
 * About item, Quit/Cmd+Q routed through the regular quit path, the Dock
 * reopen handler and the URL/document open handler.
 *
 * Must be called before the first #VirtViewerWindow is created, because a
 * window installs its menu bar — and with it calls gtkosx_application_ready()
 * — as soon as it is built.
 */
void
virt_viewer_macos_init(VirtViewerApp *app)
{
    GtkosxApplication *osxapp;
    GtkWidget *about;

    g_return_if_fail(VIRT_VIEWER_IS_APP(app));

    osxapp = gtkosx_application_get();

    gtkosx_application_set_use_quartz_accelerators(osxapp, TRUE);

    /* The Cocoa app menu is built by gtk-mac-integration, not from our
     * GMenu models, so About gets its own item wired straight to the
     * dialog rather than to the "win.about" action. */
    about = gtk_menu_item_new_with_label(_("About"));
    gtk_widget_show(about);
    g_signal_connect(about, "activate",
                     G_CALLBACK(virt_viewer_macos_about_activate), app);
    gtkosx_application_set_about_item(osxapp, about);
    g_object_set_data_full(G_OBJECT(app), VIRT_VIEWER_MACOS_ABOUT_KEY,
                           g_object_ref_sink(about), g_object_unref);

    g_signal_connect(osxapp, "NSApplicationBlockTermination",
                     G_CALLBACK(virt_viewer_macos_block_termination), app);
    g_signal_connect(osxapp, "NSApplicationDidBecomeActive",
                     G_CALLBACK(virt_viewer_macos_did_become_active), app);
    /* Despite the name this fires for URL opens as well as document opens:
     * gtk-mac-integration implements -application:openURLs: and emits it once
     * per NSURL. */
    g_signal_connect(osxapp, "NSApplicationOpenFile",
                     G_CALLBACK(virt_viewer_macos_open_file), app);
}

static void
virt_viewer_macos_install_menubar(GtkWidget *menubar)
{
    /* There is one Cocoa menu bar but one GtkMenuBar per window, so the bar
     * has to follow the focus. Reinstalling the one that is already mirrored
     * would re-add gtk-mac-integration's accel group to its window. */
    if (menubar == virt_viewer_macos_current_menubar)
        return;

    gtkosx_application_set_menu_bar(gtkosx_application_get(),
                                    GTK_MENU_SHELL(menubar));
    virt_viewer_macos_current_menubar = menubar;
}

static void
virt_viewer_macos_window_notify_is_active(GObject *object,
                                          GParamSpec *pspec G_GNUC_UNUSED,
                                          gpointer opaque G_GNUC_UNUSED)
{
    GtkWidget *menubar;

    if (!gtk_window_is_active(GTK_WINDOW(object)))
        return;

    menubar = g_object_get_data(object, VIRT_VIEWER_MACOS_MENUBAR_KEY);
    if (menubar == NULL)
        return;

    virt_viewer_macos_install_menubar(menubar);
}

/**
 * virt_viewer_macos_window_set_menubar:
 * @win: the #VirtViewerWindow
 * @menubar: a #GtkMenuBar already packed into @win's widget hierarchy
 *
 * Mirror @menubar into the global macOS menu bar whenever @win is the active
 * window. @menubar is kept permanently hidden, so it is never drawn inside the
 * window; it exists only as the model gtk-mac-integration reads. It must
 * already have @win's #GtkWindow as an ancestor, because gtk-mac-integration
 * installs the menu accelerators on gtk_widget_get_toplevel(@menubar).
 */
void
virt_viewer_macos_window_set_menubar(VirtViewerWindow *win, GtkWidget *menubar)
{
    static gboolean app_ready = FALSE;
    GtkWindow *window;

    g_return_if_fail(VIRT_VIEWER_IS_WINDOW(win));
    g_return_if_fail(GTK_IS_MENU_BAR(menubar));

    window = virt_viewer_window_get_window(win);
    g_return_if_fail(gtk_widget_get_toplevel(menubar) == GTK_WIDGET(window));

    /* gtk-mac-integration skips menu items that are not visible, so show
     * everything first, then hide the bar itself and opt it out of the
     * window's gtk_widget_show_all() so it stays hidden for good. */
    gtk_widget_show_all(menubar);
    gtk_widget_hide(menubar);
    gtk_widget_set_no_show_all(menubar, TRUE);

    /* The window owns the widget; this is only a lookup handle for the
     * focus tracking below. */
    g_object_set_data(G_OBJECT(window), VIRT_VIEWER_MACOS_MENUBAR_KEY, menubar);

    g_signal_connect(window, "notify::is-active",
                     G_CALLBACK(virt_viewer_macos_window_notify_is_active), NULL);

    virt_viewer_macos_install_menubar(menubar);

    if (!app_ready) {
        /* Only meaningful once, and only once a menu bar exists. */
        gtkosx_application_ready(gtkosx_application_get());
        app_ready = TRUE;
    }
}
