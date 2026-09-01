/*
 * vsm-keymap.h: osx keycode -> XT (AT set 1) scancode lookup.
 *
 * The table itself lives in vsm-keymap.c, which is generated verbatim from
 * keycodemapdb -- the same database qemu and spice-gtk use:
 *
 *   keymap-gen code-map --lang=stdc --varname=osx_to_xtkbd \
 *              keymaps.csv osx xtkbd > vsm-keymap.c
 *
 * Do not hand-edit vsm-keymap.c; regenerate it.
 */
#ifndef VSM_KEYMAP_H
#define VSM_KEYMAP_H

/* Indexed by NSEvent.keyCode; 0 means "no XT scancode for this key". */
extern const unsigned short osx_to_xtkbd[256];

#endif /* VSM_KEYMAP_H */
