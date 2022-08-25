/*
 * Virt Viewer: A virtual machine console viewer
 *
 * Copyright (C) 2007-2014 Red Hat, Inc.
 * Copyright (C) 2009-2012 Daniel P. Berrange
 * Copyright (C) 2010 Marc-André Lureau
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
 *         Christophe Fergeau <cfergeau@redhat.com>
 */

#pragma once

#include <glib-object.h>
#include <govirt/govirt.h>
#include <gtk/gtk.h>

#include "virt-viewer-file.h"

#define OVIRT_TYPE_FOREIGN_MENU ovirt_foreign_menu_get_type()
G_DECLARE_FINAL_TYPE(OvirtForeignMenu,
                     ovirt_foreign_menu,
                     OVIRT,
                     FOREIGN_MENU,
                     GObject)

GType ovirt_foreign_menu_get_type(void);

OvirtForeignMenu* ovirt_foreign_menu_new(OvirtProxy *proxy);
OvirtForeignMenu *ovirt_foreign_menu_new_from_file(VirtViewerFile *self);

void ovirt_foreign_menu_fetch_iso_names_async(OvirtForeignMenu *menu,
                                              GCancellable *cancellable,
                                              GAsyncReadyCallback callback,
                                              gpointer user_data);
GList *ovirt_foreign_menu_fetch_iso_names_finish(OvirtForeignMenu *foreign_menu,
                                                 GAsyncResult *result,
                                                 GError **error);

void ovirt_foreign_menu_set_current_iso_name_async(OvirtForeignMenu *foreign_menu,
                                                   const char *name,
                                                   const char *id,
                                                   GCancellable *cancellable,
                                                   GAsyncReadyCallback callback,
                                                   gpointer user_data);
gboolean ovirt_foreign_menu_set_current_iso_name_finish(OvirtForeignMenu *foreign_menu,
                                                        GAsyncResult *result,
                                                        GError **error);


gchar *ovirt_foreign_menu_get_current_iso_name(OvirtForeignMenu *menu);
GList *ovirt_foreign_menu_get_iso_names(OvirtForeignMenu *menu);
GStrv  ovirt_foreign_menu_get_current_iso_info(OvirtForeignMenu *menu);
