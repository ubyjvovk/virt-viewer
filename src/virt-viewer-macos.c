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
/* Where the VirtViewerApp keeps the app-menu About item alive. */
#define VIRT_VIEWER_MACOS_ABOUT_KEY "virt-viewer-macos-about-item"

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

/**
 * virt_viewer_macos_init:
 * @app: the #VirtViewerApp
 *
 * Set up the macOS application-wide integration: Quartz accelerators (so GTK
 * renders accelerators as ⌘ combinations in the Cocoa menu bar), the app menu
 * About item, Quit/Cmd+Q routed through the regular quit path, and the Dock
 * reopen handler.
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
}

static void
virt_viewer_macos_window_notify_is_active(GObject *object,
                                          GParamSpec *pspec G_GNUC_UNUSED,
                                          gpointer opaque G_GNUC_UNUSED)
{
    GtkWindow *window = GTK_WINDOW(object);
    GtkWidget *menubar;

    if (!gtk_window_is_active(window))
        return;

    menubar = g_object_get_data(object, VIRT_VIEWER_MACOS_MENUBAR_KEY);
    if (menubar == NULL)
        return;

    /* There is one Cocoa menu bar but one GtkMenuBar per window, so the bar
     * has to follow the focus. */
    gtkosx_application_set_menu_bar(gtkosx_application_get(),
                                    GTK_MENU_SHELL(menubar));
}

/**
 * virt_viewer_macos_window_set_menubar:
 * @win: the #VirtViewerWindow
 * @menubar: a #GtkMenuBar that is not part of any widget hierarchy
 *
 * Take ownership of @menubar and mirror it into the global macOS menu bar
 * whenever @win is the active window. @menubar is never drawn in the window
 * itself; it exists only as the model gtk-mac-integration reads.
 */
void
virt_viewer_macos_window_set_menubar(VirtViewerWindow *win, GtkWidget *menubar)
{
    static gboolean app_ready = FALSE;
    GtkWindow *window;

    g_return_if_fail(VIRT_VIEWER_IS_WINDOW(win));
    g_return_if_fail(GTK_IS_MENU_BAR(menubar));

    /* gtk-mac-integration skips menu items that are not visible, so show
     * everything first and then hide only the bar itself. */
    gtk_widget_show_all(menubar);
    gtk_widget_hide(menubar);

    window = virt_viewer_window_get_window(win);
    g_object_set_data_full(G_OBJECT(window), VIRT_VIEWER_MACOS_MENUBAR_KEY,
                           g_object_ref_sink(menubar), g_object_unref);

    g_signal_connect(window, "notify::is-active",
                     G_CALLBACK(virt_viewer_macos_window_notify_is_active), NULL);

    gtkosx_application_set_menu_bar(gtkosx_application_get(),
                                    GTK_MENU_SHELL(menubar));

    if (!app_ready) {
        /* Only meaningful once, and only once a menu bar exists. */
        gtkosx_application_ready(gtkosx_application_get());
        app_ready = TRUE;
    }
}
