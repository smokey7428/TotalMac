#!/bin/bash
# Builds TotalMac, assembles a double-clickable TotalMac.app in ./dist, stamps it
# with a version and archives the build in ./dist/versions.
#
#   ./build.sh                  release build, version bumped and archived
#   ./build.sh debug            debug build instead of release
#   ARCHIVE=0 ./build.sh        build only, do not keep a copy in dist/versions
#   KEEP=10 ./build.sh          keep the newest 10 archived builds (default 20)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

CONFIGURATION="${1:-release}"
APP_NAME="TotalMac"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
VERSIONS="$DIST/versions"
KEEP="${KEEP:-20}"
ARCHIVE="${ARCHIVE:-1}"

# ---------------------------------------------------------------- version stamp
VERSION="$(tr -d '[:space:]' < "$ROOT/VERSION" 2>/dev/null || echo 0.0.0)"
if [ -z "$VERSION" ]; then VERSION="0.0.0"; fi

BUILD_FILE="$ROOT/.build-number"
BUILD="$(cat "$BUILD_FILE" 2>/dev/null || echo 0)"
case "$BUILD" in (*[!0-9]*|"") BUILD=0 ;; esac
BUILD=$((BUILD + 1))
echo "$BUILD" > "$BUILD_FILE"

BUILD_DATE="$(date '+%Y-%m-%d %H:%M')"
BUILD_STAMP="$(date '+%Y%m%d-%H%M')"

echo "==> Building $APP_NAME $VERSION (build $BUILD)"
swift build -c "$CONFIGURATION"

BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$APP_NAME"
if [ ! -x "$BINARY" ]; then
  echo "!! binary not found at $BINARY" >&2
  exit 1
fi

echo "==> Assembling app bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist" >/dev/null
if /usr/libexec/PlistBuddy -c "Set :TotalMacBuildNumber $BUILD" "$APP/Contents/Info.plist" >/dev/null 2>&1; then :; else
  /usr/libexec/PlistBuddy -c "Add :TotalMacBuildNumber integer $BUILD" "$APP/Contents/Info.plist" >/dev/null
fi
if /usr/libexec/PlistBuddy -c "Set :TotalMacBuildDate $BUILD_DATE" "$APP/Contents/Info.plist" >/dev/null 2>&1; then :; else
  /usr/libexec/PlistBuddy -c "Add :TotalMacBuildDate string $BUILD_DATE" "$APP/Contents/Info.plist" >/dev/null
fi

echo "==> Generating icon"
ICONSET="$ROOT/.build/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$ROOT/scripts/make_icon.swift" "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || {
  echo "!! ad-hoc signing failed, the app will still run locally" >&2
}

# ---------------------------------------------------------------- archive
if [ "$ARCHIVE" = "1" ]; then
  mkdir -p "$VERSIONS"
  ARCHIVED="$VERSIONS/$APP_NAME-$VERSION-b$BUILD-$BUILD_STAMP.app"
  rm -rf "$ARCHIVED"
  cp -R "$APP" "$ARCHIVED"
  echo "==> Archived $APP_NAME-$VERSION-b$BUILD"

  # Keep the folder from growing without bound (newest first by build number).
  COUNT="$(ls -1 "$VERSIONS" 2>/dev/null | grep -c '\.app$' || true)"
  if [ "$COUNT" -gt "$KEEP" ]; then
    ls -1dt "$VERSIONS"/*.app 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
      rm -rf "$old"
    done
    echo "==> Pruned old builds, keeping the newest $KEEP"
  fi
fi

# Refresh Launch Services so Finder picks up the new icon and version
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$APP" >/dev/null 2>&1 || true

echo
echo "Built:   $APP"
echo "Version: $VERSION (build $BUILD), $BUILD_DATE"
if [ "$ARCHIVE" = "1" ]; then
  echo "Kept:    $VERSIONS/$APP_NAME-$VERSION-b$BUILD-$BUILD_STAMP.app"
fi
echo "Run with: open \"$APP\""
