#!/usr/bin/env python3

import os
import os.path
import subprocess
import sys

if "MESON_INSTALL_PREFIX" not in os.environ:
   print("This is meant to be run from Meson only", file=sys.stderr)
   sys.exit(1)

# If installing into a DESTDIR we assume
# this is a distro packaging build, so skip actions
if os.environ.get("DESTDIR", "") != "":
   sys.exit(0)

if len(sys.argv) != 4:
   print("%s UPDATE-MIME-DATABASE UPDATE-ICON-CACHE UPDATE-DESKTOP-DATABASE")
   sys.exit(1)

prefix = os.environ["MESON_INSTALL_PREFIX"]

update_mime_database = sys.argv[1]
update_icon_cache = sys.argv[2]
update_desktop_database = sys.argv[3]
mime_dir = os.path.join(prefix, "share", "mime")

if update_mime_database != "" and os.path.isdir(mime_dir):
   print("Updating mime database")
   subprocess.run([update_mime_database, mime_dir],
                  check=True)
else:
   print("Skipping mime database update")

if update_icon_cache != "":
   print("Updating icon cache")
   subprocess.run([update_icon_cache, "-qtf",
                   os.path.join(prefix, "share", "icons", "hicolor")],
                  check=True)
else:
   print("Skipping icon cache update")

if update_desktop_database != "":
   print("Updating desktop database")
   subprocess.run([update_desktop_database, "-q",
                   os.path.join(prefix, "share", "applications")],
                  check=True)
else:
   print("Skipping desktop database update")
