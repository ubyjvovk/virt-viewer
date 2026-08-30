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

void virt_viewer_macos_init(VirtViewerApp *app);
void virt_viewer_macos_window_set_menubar(VirtViewerWindow *win, GtkWidget *menubar);
