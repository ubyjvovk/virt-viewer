/*
 * Virt Viewer: A virtual machine console viewer
 *
 * Copyright (C) 2007-2012 Red Hat, Inc.
 * Copyright (C) 2009-2012 Daniel P. Berrange
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
 *
 * Author: Daniel P. Berrange <berrange@redhat.com>
 */

#pragma once

#include <gtk/gtk.h>

extern gboolean doDebug;

enum {
    VIRT_VIEWER_ERROR_FAILED,
    VIRT_VIEWER_ERROR_CANCELLED
};

#define VIRT_VIEWER_ERROR virt_viewer_error_quark ()
#define VIRT_VIEWER_RESOURCE_PREFIX "/org/virt-manager/virt-viewer"

GQuark virt_viewer_error_quark(void);

/**
 * virt_viewer_util_get_bundle_resources_dir:
 *
 * Returns the path to the "Contents/Resources" directory of the current
 * macOS application bundle, or NULL when the process is not running from
 * inside a .app bundle (for instance a plain build or an installed
 * binary). On non-macOS platforms this always returns NULL.
 *
 * The returned string is newly allocated; free it with g_free().
 *
 * Returns: (transfer full): the bundle resources directory, or NULL.
 */
gchar *virt_viewer_util_get_bundle_resources_dir(void);

void virt_viewer_util_init(const char *appname);

GtkBuilder *virt_viewer_util_load_ui(const char *name);
int virt_viewer_util_extract_host(const char *uristr,
                                  char **scheme,
                                  char **host,
                                  char **transport,
                                  char **user,
                                  int *port);

gulong virt_viewer_signal_connect_object(gpointer instance,
                                         const gchar *detailed_signal,
                                         GCallback c_handler,
                                         gpointer gobject,
                                         GConnectFlags connect_flags);

gchar* spice_hotkey_to_gtk_accelerator(const gchar *key);
gchar* spice_hotkey_to_display_hotkey(const gchar *key);
gint virt_viewer_compare_buildid(const gchar *s1, const gchar *s2);

/* monitor alignment */
void virt_viewer_align_monitors_linear(GHashTable *displays);
void virt_viewer_shift_monitors_to_origin(GHashTable *displays);

/* monitor mapping */
GHashTable* virt_viewer_parse_monitor_mappings(gchar **mappings,
                                               const gsize nmappings,
                                               const gint nmonitors);

int virt_viewer_enum_from_string(GType enum_type, gchar *name);
