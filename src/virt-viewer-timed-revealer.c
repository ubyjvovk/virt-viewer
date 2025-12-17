/*
 * Virt Viewer: A virtual machine console viewer
 *
 * Copyright (c) 2016 Red Hat, Inc.
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
 * Author: Cole Robinson <crobinso@redhat.com>
 * Author: Fabiano Fidêncio <fidencio@redhat.com>
 */

#include <config.h>

#include "virt-viewer-timed-revealer.h"

struct _VirtViewerTimedRevealer
{
    GtkEventBox parent;
    gboolean fullscreen;
    guint timeout_id;

    GtkWidget *revealer;
};

G_DEFINE_TYPE(VirtViewerTimedRevealer, virt_viewer_timed_revealer, GTK_TYPE_EVENT_BOX)

static void
virt_viewer_timed_revealer_unregister_timeout(VirtViewerTimedRevealer *self)
{
    if (self->timeout_id) {
        g_source_remove(self->timeout_id);
        self->timeout_id = 0;
    }
}

static gboolean
schedule_unreveal_timeout_cb(VirtViewerTimedRevealer *self)
{
    gtk_revealer_set_reveal_child(GTK_REVEALER(self->revealer), FALSE);
    self->timeout_id = 0;

    return FALSE;
}

static void
virt_viewer_timed_revealer_schedule_unreveal_timeout(VirtViewerTimedRevealer *self,
                                                     guint timeout)
{
    if (self->timeout_id != 0)
        return;

    self->timeout_id = g_timeout_add(timeout,
                                     (GSourceFunc)schedule_unreveal_timeout_cb,
                                     self);
}

static void
virt_viewer_timed_revealer_grab_notify(VirtViewerTimedRevealer *self,
                                       gboolean was_grabbed,
                                       gpointer user_data G_GNUC_UNUSED)
{
    if (was_grabbed)
        virt_viewer_timed_revealer_schedule_unreveal_timeout(self, 1000);
}

static gboolean
virt_viewer_timed_revealer_enter_notify(VirtViewerTimedRevealer *self,
                                        GdkEventCrossing *event G_GNUC_UNUSED,
                                        gpointer user_data G_GNUC_UNUSED)
{
    if (!self->fullscreen)
        return FALSE;

    virt_viewer_timed_revealer_unregister_timeout(self);
    if (!gtk_revealer_get_reveal_child(GTK_REVEALER(self->revealer))) {
        gtk_revealer_set_reveal_child(GTK_REVEALER(self->revealer), TRUE);
    }

    return FALSE;
}

static gboolean
virt_viewer_timed_revealer_leave_notify(VirtViewerTimedRevealer *self,
                                        GdkEventCrossing *event G_GNUC_UNUSED,
                                        gpointer user_data G_GNUC_UNUSED)
{
    if (!self->fullscreen)
        return FALSE;

    /*
     * Pointer exited the toolbar, and toolbar is revealed. Schedule
     * a timeout to close it, if one isn't already scheduled.
     */
    if (gtk_revealer_get_reveal_child(GTK_REVEALER(self->revealer))) {
        virt_viewer_timed_revealer_schedule_unreveal_timeout(self, 1000);
    }

    return FALSE;
}

static void
virt_viewer_timed_revealer_init(VirtViewerTimedRevealer *self G_GNUC_UNUSED)
{
}

static void
virt_viewer_timed_revealer_dispose(GObject *object)
{
    VirtViewerTimedRevealer *self = VIRT_VIEWER_TIMED_REVEALER(object);

    self->revealer = NULL;

    if (self->timeout_id) {
        g_source_remove(self->timeout_id);
        self->timeout_id = 0;
    }

    G_OBJECT_CLASS(virt_viewer_timed_revealer_parent_class)->dispose(object);
}


static void
virt_viewer_timed_revealer_class_init(VirtViewerTimedRevealerClass *klass)
{
   GObjectClass *object_class = G_OBJECT_CLASS(klass);

   object_class->dispose = virt_viewer_timed_revealer_dispose;
}

VirtViewerTimedRevealer *
virt_viewer_timed_revealer_new(GtkWidget *toolbar)
{
    VirtViewerTimedRevealer *self;

    self = g_object_new(VIRT_VIEWER_TYPE_TIMED_REVEALER, NULL);

    self->fullscreen = FALSE;
    self->timeout_id = 0;

    self->revealer = gtk_revealer_new();
    gtk_container_add(GTK_CONTAINER(self->revealer), toolbar);

    /*
     * Adding the revealer to the eventbox seems to ensure the
     * GtkEventBox always has 1 invisible pixel showing at the top of the
     * screen, which we can use to grab the pointer event to show
     * the hidden toolbar.
     */

    gtk_container_add(GTK_CONTAINER(self), self->revealer);
    gtk_widget_show(self->revealer);
    gtk_widget_set_halign(GTK_WIDGET(self), GTK_ALIGN_CENTER);
    gtk_widget_set_valign(GTK_WIDGET(self), GTK_ALIGN_START);
    gtk_widget_show(GTK_WIDGET(self));

    g_signal_connect(self,
                     "grab-notify",
                     G_CALLBACK(virt_viewer_timed_revealer_grab_notify),
                     NULL);
    g_signal_connect(self,
                     "enter-notify-event",
                     G_CALLBACK(virt_viewer_timed_revealer_enter_notify),
                     NULL);
    g_signal_connect(self,
                     "leave-notify-event",
                     G_CALLBACK(virt_viewer_timed_revealer_leave_notify),
                     NULL);

    return self;
}

void
virt_viewer_timed_revealer_force_reveal(VirtViewerTimedRevealer *self,
                                        gboolean fullscreen)
{
    g_return_if_fail(VIRT_VIEWER_IS_TIMED_REVEALER(self));

    virt_viewer_timed_revealer_unregister_timeout(self);
    self->fullscreen = fullscreen;
    gtk_revealer_set_reveal_child(GTK_REVEALER(self->revealer), fullscreen);
    if (fullscreen)
        virt_viewer_timed_revealer_schedule_unreveal_timeout(self, 2000);
}
