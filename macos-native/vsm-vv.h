/*
 * vsm-vv.h: parser for virt-viewer ".vv" connection files.
 *
 * A .vv file is the little GKeyFile that oVirt/RHV, virt-manager and Proxmox
 * hand a browser so that double-clicking it opens a viewer on a running VM.
 * Only the SPICE subset this viewer can actually honour is understood; every
 * other key is logged once and ignored, so an unsupported file still connects
 * rather than failing.
 *
 * Pure GLib: no AppKit, no SPICE.  main.m turns the result into a connection.
 */
#ifndef VSM_VV_H
#define VSM_VV_H

#include <glib.h>

/* What a .vv file asked for, once the unsupported half has been discarded. */
typedef struct {
    char     *uri;          /* "spice://host:port", ready for vsm_spice_new() */
    char     *password;     /* NULL when the file carried none */
    gboolean  delete_file;  /* the file said delete-this-file=1 */
} VsmVvFile;

/* Parse the .vv file at @path.  Returns a newly allocated VsmVvFile on
 * success, or NULL with @error set (G_KEY_FILE_ERROR / G_FILE_ERROR domains,
 * or VSM_VV_ERROR for a file that parses but asks for something this viewer
 * cannot do).  The message is written for a user-facing alert. */
VsmVvFile *vsm_vv_parse(const char *path, GError **error);

/* Delete the file at @path, as requested by delete-this-file=1.  A .vv file
 * usually carries a one-shot password, so failing to remove it is worth a
 * warning; it is never fatal. */
void vsm_vv_delete(const char *path);

void vsm_vv_free(VsmVvFile *vv);

#define VSM_VV_ERROR (vsm_vv_error_quark())
GQuark vsm_vv_error_quark(void);

typedef enum {
    VSM_VV_ERROR_NOT_SPICE,   /* type= is missing or is not "spice" */
    VSM_VV_ERROR_NO_HOST,     /* host= or port= is missing */
} VsmVvErrorCode;

#endif /* VSM_VV_H */
