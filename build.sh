#!/bin/bash
# Build the app; optionally install or run it.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$HERE/build"
BUILD="$(mktemp -d "$HERE/.build-stage.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
APP="$BUILD/JustCleaner.app"
NAME="JustCleaner"
BUNDLE_ID="com.mactidy.menubar"
MIN_MACOS="11.0"

say()  { printf '%s\n' "$*"; }
fail() {
  printf 'error: %s\n' "$*" >&2
  mkdir -p "$OUTPUT"
  for log in "$BUILD"/build-*.log; do
    [ ! -f "$log" ] || cp "$log" "$OUTPUT/"
  done
  exit 1
}

WANT_INSTALL=0
WANT_RUN=0
for arg in "$@"; do
  case "$arg" in
    --install) WANT_INSTALL=1 ;;
    --run)     WANT_RUN=1 ;;
    -h|--help) say "Usage: ./build.sh [--install] [--run]"; exit 0 ;;
    *) printf 'unknown option: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || fail "JustCleaner is for macOS."

if ! xcrun --find swiftc >/dev/null 2>&1; then
  cat >&2 <<'EOS'
error: swiftc is missing, so nothing can be compiled on this Mac.

  Either install Apple's command line tools:   xcode-select --install
  Or build JustCleaner on another Mac, click
  "More > Export app for another Mac…" in its menu, and use the zip it leaves on the
  Desktop. That route needs no tools at all on this machine.
EOS
  exit 1
fi

# One source of truth for the version: the Swift file the app itself reports from.
VERSION="$(/usr/bin/sed -n 's/.*static let string = "\([^"]*\)".*/\1/p' \
  "$HERE/Sources/Core/Environment.swift" | head -1)"
[ -n "$VERSION" ] || fail "could not read the version from Sources/Core/Environment.swift"

# Paths with spaces are normal on a Mac, so keep the file list in a real array.
SOURCES=()
while IFS= read -r file; do
  SOURCES+=("$file")
done < <(find "$HERE/Sources" -name '*.swift' -type f | sort)
[ "${#SOURCES[@]}" -gt 0 ] || fail "no Swift sources found under $HERE/Sources"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$HERE/assets/JustCleaner.icns" "$APP/Contents/Resources/JustCleaner.icns"

say "Compiling $NAME $VERSION for macOS $MIN_MACOS and later…"

compile_arch() {
  swiftc -O -swift-version 5 \
    -target "${1}-apple-macosx${MIN_MACOS}" \
    -framework AppKit \
    -o "$2" "${SOURCES[@]}"
}

SLICES=()
if compile_arch arm64 "$BUILD/slice-arm64" >"$BUILD/build-arm64.log" 2>&1; then
  SLICES+=("$BUILD/slice-arm64")
  say "  apple silicon : ok"
else
  say "  apple silicon : failed"
  tail -30 "$BUILD/build-arm64.log" >&2
fi

if compile_arch x86_64 "$BUILD/slice-x86_64" >"$BUILD/build-x86_64.log" 2>&1; then
  SLICES+=("$BUILD/slice-x86_64")
  say "  intel         : ok"
else
  say "  intel         : skipped, this Mac cannot build that slice"
fi

case "${#SLICES[@]}" in
  0) fail "compilation failed - see $OUTPUT/build-arm64.log" ;;
  1) cp "${SLICES[0]}" "$APP/Contents/MacOS/$NAME" || fail "could not place the binary" ;;
  *) lipo -create -output "$APP/Contents/MacOS/$NAME" "${SLICES[@]}" || fail "lipo failed" ;;
esac
chmod +x "$APP/Contents/MacOS/$NAME"
rm -f "$BUILD"/slice-*

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key><string>JustCleaner</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Yours. Do what you like with it.</string>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signing provides code integrity for this local build. It is not
# notarization and does not guarantee TCC permissions survive future rebuilds.
if codesign --force --deep --sign - "$APP" >/dev/null 2>&1; then
  say "Signed, ad-hoc."
else
  say "Could not sign. The app still runs."
fi

"$APP/Contents/MacOS/$NAME" version >/dev/null 2>&1 || fail "the built binary does not run"
mkdir -p "$OUTPUT"
# Keep the previous working build until the replacement has compiled and run.
if [ -d "$OUTPUT/JustCleaner.app" ]; then
  mv "$OUTPUT/JustCleaner.app" "$BUILD/previous.app"
fi
if ! mv "$APP" "$OUTPUT/JustCleaner.app"; then
  [ ! -d "$BUILD/previous.app" ] || mv "$BUILD/previous.app" "$OUTPUT/JustCleaner.app"
  fail "could not publish the new build"
fi
cp "$BUILD"/build-*.log "$OUTPUT/"
APP="$OUTPUT/JustCleaner.app"
say "Built: $APP"
say "Architectures: $(lipo -archs "$APP/Contents/MacOS/$NAME" 2>/dev/null)"

if [ "$WANT_INSTALL" = "1" ]; then
  # Stage the replacement before stopping or replacing an installed copy.
  INSTALL_PARENT="/Applications"
  STAGE="$(mktemp -d "$INSTALL_PARENT/.mactidy-install.XXXXXX" 2>/dev/null)" || {
    INSTALL_PARENT="$HOME/Applications"
    mkdir -p "$INSTALL_PARENT"
    STAGE="$(mktemp -d "$INSTALL_PARENT/.mactidy-install.XXXXXX")" || fail "could not stage installation"
  }
  if ! ditto "$APP" "$STAGE/JustCleaner.app"; then
    rm -rf "$STAGE"
    fail "could not copy the app"
  fi
  DEST="$INSTALL_PARENT/JustCleaner.app"
  pkill -x "$NAME" >/dev/null 2>&1 || true
  pkill -x Beryl >/dev/null 2>&1 || true
  pkill -x MacTidy >/dev/null 2>&1 || true
  if [ -e "$DEST" ] && ! mv "$DEST" "$STAGE/previous.app"; then
    rm -rf "$STAGE"
    fail "could not replace $DEST"
  fi
  if ! mv "$STAGE/JustCleaner.app" "$DEST"; then
    [ ! -e "$STAGE/previous.app" ] || mv "$STAGE/previous.app" "$DEST"
    fail "could not install; staging files kept at $STAGE"
  fi
  rm -rf "$STAGE"
  if [ -n "${JUSTCLEANER_INSTALL_RESULT:-}" ]; then
    printf '%s\n' "$DEST" > "$JUSTCLEANER_INSTALL_RESULT"
  fi
  xattr -dr com.apple.quarantine "$DEST" >/dev/null 2>&1 || true
  # Retain the existing login preference while updating its executable path.
  if [ -f "$HOME/Library/LaunchAgents/$BUNDLE_ID.plist" ]; then
    "$DEST/Contents/MacOS/$NAME" login-item || say "Could not update start at login; retry in JustCleaner Settings."
  fi
  say "Installed: $DEST"
  open "$DEST" || fail "could not launch"
  say "Look for the sparkle icon in the menu bar."
fi

if [ "$WANT_RUN" = "1" ]; then
  exec "$APP/Contents/MacOS/$NAME" --menubar
fi

exit 0
