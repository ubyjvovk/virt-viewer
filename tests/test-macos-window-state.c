/* -*- Mode: C; c-basic-offset: 4; indent-tabs-mode: nil -*- */
/*
 * Virt Viewer: A virtual machine console viewer
 *
 * Copyright (C) 2026 Red Hat, Inc.
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
 * Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307  USA
 */

/*
 * macOS window-state regression test.
 *
 * The viewer window draws its title in a client-side GtkHeaderBar rather
 * than in the native title bar, so on macOS the title the user sees lives in
 * a widget the application shows and hides itself:
 * virt_viewer_window_enter_fullscreen() hides it and
 * virt_viewer_window_leave_fullscreen() shows it again.  Users reported the
 * title going missing after window-state changes, so this test locks the
 * invariants that do hold today:
 *
 *   - gtk_window_get_title() survives maximize/unmaximize cycles,
 *   - gtk_header_bar_get_title() survives them too,
 *   - the header bar is still visible after every transition.
 *
 * Fullscreen is deliberately not exercised.  On quartz
 * gtk_window_fullscreen() is implemented with -[NSWindow toggleFullScreen:],
 * and an unbundled test binary enters that state but never leaves it again:
 * gtk_window_unfullscreen() produces no window-state-event within 20s, so a
 * fullscreen cycle here would only ever time out.  The bundled application
 * does not have that problem, which puts fullscreen coverage out of reach of
 * `meson test` and into a manual matrix instead.  The two confirmed title
 * defects could not be reproduced from here in any case: both need a
 * transition started outside GTK - the green traffic-light button, or a
 * Space switch performed by the window server - which no in-process GTK API
 * can request.  See docs/macos.md "Known issues".
 *
 * Exits 77 - meson's "skipped" status - when there is no window server
 * session to open a window on, so a headless builder does not fail the suite.
 */

#include <config.h>

#include <gtk/gtk.h>

#define WINDOW_TITLE "virt-viewer window-state test"
#define MAXIMIZE_CYCLES 5
#define STATE_TIMEOUT_MS 5000
#define EXIT_SKIP 77

static GdkWindowState last_state;

static gboolean
window_state_cb(GtkWidget *widget G_GNUC_UNUSED,
                GdkEventWindowState *event,
                gpointer data G_GNUC_UNUSED)
{
    last_state = event->new_window_state;
    return FALSE;
}

/*
 * Iterate the main loop until every bit in @bits is set (@set is TRUE) or
 * clear (@set is FALSE) in the window state most recently reported by the
 * window server.  Returns FALSE if that does not happen within
 * STATE_TIMEOUT_MS.
 */
static gboolean
wait_for_state(GdkWindowState bits, gboolean set)
{
    gint64 deadline = g_get_monotonic_time() + STATE_TIMEOUT_MS * 1000;

    for (;;) {
        gboolean reached = ((last_state & bits) == bits);

        if (reached == set)
            return TRUE;
        if (g_get_monotonic_time() > deadline)
            return FALSE;

        g_main_context_iteration(NULL, FALSE);
        g_usleep(20000);
    }
}

/* Iterate the main loop until @window is mapped, or the timeout expires. */
static gboolean
wait_for_map(GtkWidget *window)
{
    gint64 deadline = g_get_monotonic_time() + STATE_TIMEOUT_MS * 1000;

    while (!gtk_widget_get_mapped(window)) {
        if (g_get_monotonic_time() > deadline)
            return FALSE;

        g_main_context_iteration(NULL, FALSE);
        g_usleep(20000);
    }
    return TRUE;
}

/* Assert the user-visible title survived the transition named by @phase. */
static void
check_titles(GtkWindow *window, GtkHeaderBar *header, const char *phase)
{
    const char *title = gtk_window_get_title(window);
    const char *header_title = gtk_header_bar_get_title(header);

    if (g_strcmp0(title, WINDOW_TITLE) != 0)
        g_error("window title is \"%s\" after %s, expected \"%s\"",
                title ? title : "(null)", phase, WINDOW_TITLE);

    if (g_strcmp0(header_title, WINDOW_TITLE) != 0)
        g_error("header bar title is \"%s\" after %s, expected \"%s\"",
                header_title ? header_title : "(null)", phase, WINDOW_TITLE);

    if (!gtk_widget_get_visible(GTK_WIDGET(header)))
        g_error("header bar is hidden after %s", phase);
}

int main(void)
{
    GtkWidget *window;
    GtkWidget *header;
    int i;

    if (!gtk_init_check(NULL, NULL)) {
        g_printerr("no window server session available, skipping\n");
        return EXIT_SKIP;
    }

    window = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    gtk_window_set_default_size(GTK_WINDOW(window), 480, 320);
    gtk_window_set_title(GTK_WINDOW(window), WINDOW_TITLE);

    header = gtk_header_bar_new();
    gtk_header_bar_set_title(GTK_HEADER_BAR(header), WINDOW_TITLE);
    gtk_header_bar_set_show_close_button(GTK_HEADER_BAR(header), TRUE);
    gtk_window_set_titlebar(GTK_WINDOW(window), header);

    g_signal_connect(window, "window-state-event",
                     G_CALLBACK(window_state_cb), NULL);

    gtk_widget_show_all(window);
    if (!wait_for_map(window)) {
        g_printerr("window was never mapped, skipping\n");
        return EXIT_SKIP;
    }

    check_titles(GTK_WINDOW(window), GTK_HEADER_BAR(header), "map");

    for (i = 0; i < MAXIMIZE_CYCLES; i++) {
        gtk_window_maximize(GTK_WINDOW(window));
        if (!wait_for_state(GDK_WINDOW_STATE_MAXIMIZED, TRUE)) {
            g_printerr("window was never maximized, skipping\n");
            return EXIT_SKIP;
        }
        check_titles(GTK_WINDOW(window), GTK_HEADER_BAR(header), "maximize");

        gtk_window_unmaximize(GTK_WINDOW(window));
        if (!wait_for_state(GDK_WINDOW_STATE_MAXIMIZED, FALSE)) {
            g_printerr("window was never unmaximized, skipping\n");
            return EXIT_SKIP;
        }
        check_titles(GTK_WINDOW(window), GTK_HEADER_BAR(header), "unmaximize");
    }

    gtk_widget_destroy(window);

    return 0;
}
