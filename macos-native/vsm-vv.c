/*
 * vsm-vv.c: see vsm-vv.h.
 *
 * The format is a GKeyFile with a single meaningful group, [virt-viewer].
 * virt-viewer itself understands some thirty keys there (TLS material, USB
 * filters, proxies, ticket expiry, oVirt session cookies...); this viewer
 * understands four.  Rather than reject a file that carries the other
 * twenty-six -- which is every file a real oVirt deployment emits -- each
 * unknown key is announced once with g_message() and dropped.
 */
#include "vsm-vv.h"

#include <glib/gstdio.h>

#include <errno.h>
#include <string.h>

/* The only group a .vv file is required to have. */
#define VSM_VV_GROUP "virt-viewer"

G_DEFINE_QUARK(vsm-vv-error, vsm_vv_error)

/* Keys this viewer acts on.  Everything else in [virt-viewer] is logged and
 * ignored; keep this list in sync with the README's ".vv files" section. */
static const char *const vsm_vv_known_keys[] = {
    "type", "host", "port", "password", "delete-this-file", NULL,
};

static gboolean
vsm_vv_key_is_known(const char *key)
{
    return g_strv_contains(vsm_vv_known_keys, key);
}

/* Announce, once per key, everything in the file this viewer will not act on:
 * an ignored tls-port is the difference between a working session and a
 * confusing one, and the log line is the only place that shows up. */
static void
vsm_vv_log_ignored(GKeyFile *kf, const char *path)
{
    g_auto(GStrv) groups = NULL;
    gsize i;

    groups = g_key_file_get_groups(kf, NULL);
    for (i = 0; groups && groups[i]; i++) {
        g_auto(GStrv) keys = NULL;
        gsize j;

        if (!g_str_equal(groups[i], VSM_VV_GROUP)) {
            g_message("%s: ignoring unsupported group [%s]", path, groups[i]);
            continue;
        }
        keys = g_key_file_get_keys(kf, groups[i], NULL, NULL);
        for (j = 0; keys && keys[j]; j++) {
            if (!vsm_vv_key_is_known(keys[j]))
                g_message("%s: ignoring unsupported key %s", path, keys[j]);
        }
    }
}

/* Wrap a bare IPv6 literal in brackets so that appending ":port" still yields
 * a parseable URI; hostnames and IPv4 literals pass through untouched. */
static char *
vsm_vv_authority(const char *host, int port)
{
    if (strchr(host, ':') && host[0] != '[')
        return g_strdup_printf("[%s]:%d", host, port);
    return g_strdup_printf("%s:%d", host, port);
}

VsmVvFile *
vsm_vv_parse(const char *path, GError **error)
{
    g_autoptr(GKeyFile) kf = g_key_file_new();
    g_autofree char *type = NULL;
    g_autofree char *host = NULL;
    g_autofree char *authority = NULL;
    VsmVvFile *vv;
    int port;

    if (!g_key_file_load_from_file(kf, path, G_KEY_FILE_NONE, error))
        return NULL;

    vsm_vv_log_ignored(kf, path);

    /* type= decides which viewer the file is for.  A vnc or an ovirt file is
     * a perfectly valid .vv that this viewer simply cannot open, so it gets a
     * named error rather than a parse failure. */
    type = g_key_file_get_string(kf, VSM_VV_GROUP, "type", NULL);
    if (!type || !g_str_equal(type, "spice")) {
        g_set_error(error, VSM_VV_ERROR, VSM_VV_ERROR_NOT_SPICE,
                    "This connection file is for “%s” displays. "
                    "This viewer only opens SPICE connections.",
                    type ? type : "unknown");
        return NULL;
    }

    host = g_key_file_get_string(kf, VSM_VV_GROUP, "host", NULL);
    /* g_key_file_get_integer() returns 0 both for a missing key and for an
     * unparseable one; either way there is no port to connect to. */
    port = g_key_file_get_integer(kf, VSM_VV_GROUP, "port", NULL);
    if (!host || !*host || port <= 0 || port > 65535) {
        g_set_error(error, VSM_VV_ERROR, VSM_VV_ERROR_NO_HOST,
                    "This connection file has no usable host and port. "
                    "Only plain (non-TLS) SPICE connections are supported.");
        return NULL;
    }

    authority = vsm_vv_authority(host, port);

    vv = g_new0(VsmVvFile, 1);
    vv->uri = g_strconcat("spice://", authority, NULL);
    vv->password = g_key_file_get_string(kf, VSM_VV_GROUP, "password", NULL);
    vv->delete_file = g_key_file_get_boolean(kf, VSM_VV_GROUP,
                                             "delete-this-file", NULL);
    return vv;
}

void
vsm_vv_delete(const char *path)
{
    if (g_unlink(path) != 0)
        g_warning("could not delete %s as the file asked: %s",
                  path, g_strerror(errno));
}

void
vsm_vv_free(VsmVvFile *vv)
{
    if (!vv)
        return;
    g_free(vv->uri);
    if (vv->password) {
        /* The password came out of a file that usually deletes itself; do not
         * leave a copy of it in freed heap. */
        memset(vv->password, 0, strlen(vv->password));
        g_free(vv->password);
    }
    g_free(vv);
}
