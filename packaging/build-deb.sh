#!/usr/bin/env bash
#
# Build a .deb of the Shelf Mirror Wingpanel indicator.
# Usage: packaging/build-deb.sh <version>
#
# Produces shelf-mirror_<version>_<arch>.deb in the repository root.
set -euo pipefail

VERSION="${1:?usage: build-deb.sh <version>}"
ARCH="$(dpkg --print-architecture)"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/build-deb"
PKG_DIR="${ROOT}/pkgroot"
DEB="${ROOT}/shelf-mirror_${VERSION}_${ARCH}.deb"

rm -rf "${BUILD_DIR}" "${PKG_DIR}"

# Compile and stage the install into a DESTDIR. Meson skips its post-install
# schema compile when DESTDIR is set, so no stale gschemas.compiled is shipped —
# the postinst recompiles the schema cache on the target instead.
meson setup "${BUILD_DIR}" --prefix=/usr --buildtype=release
ninja -C "${BUILD_DIR}"
DESTDIR="${PKG_DIR}" meson install -C "${BUILD_DIR}"

mkdir -p "${PKG_DIR}/DEBIAN"

cat > "${PKG_DIR}/DEBIAN/control" <<EOF
Package: shelf-mirror
Version: ${VERSION}
Section: x11
Priority: optional
Architecture: ${ARCH}
Depends: libwingpanel3, libgtk-3-0t64 | libgtk-3-0, libglib2.0-0t64 | libglib2.0-0, libcairo2, libgstreamer1.0-0, libgstreamer-plugins-base1.0-0, gstreamer1.0-plugins-good, gstreamer1.0-plugins-base
Maintainer: breitburg <ilya.breytburg@gmail.com>
Homepage: https://github.com/breitburg/shelf-mirror
Description: Wingpanel camera indicator (Shelf Mirror)
 A native elementary OS Wingpanel indicator that shows a live, mirrored
 camera view in the panel, with a webcam picker and About view.
EOF

cat > "${PKG_DIR}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas || true
fi
EOF

cat > "${PKG_DIR}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    glib-compile-schemas /usr/share/glib-2.0/schemas || true
fi
EOF

chmod 0755 "${PKG_DIR}/DEBIAN/postinst" "${PKG_DIR}/DEBIAN/postrm"

dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB}"
echo "${DEB}"
