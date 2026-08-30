/*
 * Virt Viewer: A virtual machine console viewer
 *
 * macOS (Cocoa) desktop integration, built only when gtk-mac-integration is
 * available.
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

#pragma once

#include <gtk/gtk.h>

#include "virt-viewer-app.h"
#include "virt-viewer-window.h"

/**
 * VirtViewerMacosOpenUriFunc:
 * @app: the #VirtViewerApp the request was delivered to
 * @uri: a connection URI (`spice://…`, `vnc://…`) or a local path to a
 *   `.vv` connection file
 *
 * Handler for an "open this" request coming from macOS: a URL of one of the
 * schemes declared in the bundle's CFBundleURLTypes, or a document of one of
 * its CFBundleDocumentTypes.
 */
typedef void (*VirtViewerMacosOpenUriFunc)(VirtViewerApp *app, const gchar *uri);

/**
 * VirtViewerMacosCancelModalFunc:
 * @app: the #VirtViewerApp the quit request was delivered to
 *
 * Handler asked to leave whatever nested main loop the application is parked
 * in — for remote-viewer, the connect dialog — as if the user had cancelled
 * it. Called when macOS asks the application to terminate and there is no
 * session to close, because g_application_quit() cannot unwind a nested loop
 * on its own.
 *
 * Returns: %TRUE if a nested loop was asked to finish
 */
typedef gboolean (*VirtViewerMacosCancelModalFunc)(VirtViewerApp *app);

void virt_viewer_macos_init(VirtViewerApp *app);
void virt_viewer_macos_set_open_uri_func(VirtViewerMacosOpenUriFunc func);
void virt_viewer_macos_set_cancel_modal_func(VirtViewerMacosCancelModalFunc func);
gboolean virt_viewer_macos_spawn_uri(const gchar *uri, GError **error);
void virt_viewer_macos_window_set_menubar(VirtViewerWindow *win, GtkWidget *menubar);
