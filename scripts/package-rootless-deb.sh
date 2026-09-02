#!/bin/bash
set -euo pipefail

APP_PATH="${1:?Usage: package-rootless-deb.sh <app-path> <output-deb> [version]}"
OUTPUT_DEB="${2:?Usage: package-rootless-deb.sh <app-path> <output-deb> [version]}"
VERSION="${3:-0.9.0~dev1}"

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found: $APP_PATH" >&2
  exit 1
fi

ROOT="${RUNNER_TEMP:-/tmp}/xadas-rootless-deb"
rm -rf "$ROOT"
mkdir -p "$ROOT/DEBIAN" "$ROOT/var/jb/Applications"
cp -R "$APP_PATH" "$ROOT/var/jb/Applications/xADAS.app"

cat > "$ROOT/DEBIAN/control" <<EOF
Package: com.hmtnvac.xadasdev
Name: xADAS Dev
Version: $VERSION
Architecture: iphoneos-arm64
Description: xADAS development build for rootless jailbreak. 70mai RTSP ADAS testing channel.
Maintainer: xADAS Project
Author: xADAS Project
Section: Utilities
Depends: firmware (>= 16.0)
Priority: optional
Tag: role::enduser
EOF

cat > "$ROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
APP="/var/jb/Applications/xADAS.app"
if command -v uicache >/dev/null 2>&1; then
  uicache -p "$APP" || true
elif [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -p "$APP" || true
fi
exit 0
EOF

cat > "$ROOT/DEBIAN/postrm" <<'EOF'
#!/bin/sh
APP="/var/jb/Applications/xADAS.app"
if command -v uicache >/dev/null 2>&1; then
  uicache -u "$APP" || true
elif [ -x /var/jb/usr/bin/uicache ]; then
  /var/jb/usr/bin/uicache -u "$APP" || true
fi
exit 0
EOF

chmod 0755 "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/postrm"

# Preserve executable bits from the built .app. Do not chmod every file to 0644:
# embedded frameworks/dylibs contain Mach-O binaries that must remain executable.
find "$ROOT/var/jb/Applications/xADAS.app" -type d -exec chmod 0755 {} +
chmod 0755 "$ROOT/var/jb/Applications/xADAS.app/xADAS-iOS"

# Sanity-check that every Mach-O binary inside the app is executable before packaging.
while IFS= read -r -d '' FILE; do
  if file "$FILE" | grep -q 'Mach-O'; then
    chmod 0755 "$FILE"
    test -x "$FILE"
  fi
done < <(find "$ROOT/var/jb/Applications/xADAS.app" -type f -print0)

mkdir -p "$(dirname "$OUTPUT_DEB")"
dpkg-deb --root-owner-group --build "$ROOT" "$OUTPUT_DEB"

echo "Built rootless package: $OUTPUT_DEB"
dpkg-deb -I "$OUTPUT_DEB"
