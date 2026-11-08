#!/bin/bash
# Install JustCleaner from adjacent source or JUSTCLEANER_URL.

set -euo pipefail

BASE_URL="${JUSTCLEANER_URL:-}"
TMP="$(mktemp -d /tmp/justcleaner-install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

say()  { printf '%s\n' "$*"; }
fail() { printf '\nerror: %s\n\n' "$*" >&2; exit 1; }

say ""
say "JustCleaner installer"
say "-----------------"
say ""

[ "$(uname -s)" = "Darwin" ] || fail "This is for macOS."

if ! xcrun --find swiftc >/dev/null 2>&1; then
  cat >&2 <<'EOS'
This Mac has no compiler, so JustCleaner cannot be built here.

Two ways forward, pick either:

  A) Install Apple's command line tools, then run this installer again:
         xcode-select --install
     (Complete the installer, then retry.)

  B) Easier: on a Mac that already has JustCleaner, click the sparkle icon,
     choose "More > Export app for another Mac…", and AirDrop the zip file it
     leaves on the Desktop to this machine. Unzip, double-click
     "Install JustCleaner.command", done. No tools, no downloads.
EOS
  exit 1
fi

# ---- get the source ------------------------------------------------------
SCRIPT_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/build.sh" ] && [ -d "$SCRIPT_DIR/Sources" ]; then
  say "Using the source next to this script."
  SRC="$SCRIPT_DIR"
else
  [ -n "$BASE_URL" ] || fail "set JUSTCLEANER_URL to the address you downloaded this from"
  say "Downloading JustCleaner…"
  curl -fsSL "$BASE_URL/justcleaner-src.tar.gz" -o "$TMP/src.tar.gz" \
    || fail "download failed from $BASE_URL"
  mkdir -p "$TMP/src"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP/src" || fail "could not unpack the download"
  # The tarball may or may not have a wrapping folder, so find build.sh rather
  # than guessing at the first name in the listing.
  SRC="$(cd "$TMP/src" && find . -maxdepth 3 -name build.sh -type f -print | sort | head -1)"
  [ -n "$SRC" ] || fail "the download looks wrong: no build.sh inside"
  SRC="$(cd "$TMP/src/$(dirname "$SRC")" && pwd)"
  [ -d "$SRC/Sources" ] || fail "the download looks wrong: no Sources folder inside"
fi

# ---- build and install ---------------------------------------------------
chmod +x "$SRC/build.sh"
JUSTCLEANER_INSTALL_RESULT="$TMP/installed-path" "$SRC/build.sh" --install || fail "the build failed"

# ---- start at login ------------------------------------------------------
APP="$(cat "$TMP/installed-path")"
[ -x "$APP/Contents/MacOS/JustCleaner" ] || fail "installed app was not found"

if [ -t 0 ] && [ -t 1 ]; then
  printf '\nStart JustCleaner automatically when you log in? [Y/n] '
  read -r answer || answer="y"
else
  answer="y"
fi
case "${answer:-y}" in
  n|N|no|NO) say "Left as a manual app." ;;
  *) "$APP/Contents/MacOS/JustCleaner" login-item >/dev/null 2>&1 \
       && say "It will start with your Mac." \
       || say "Could not enable start at login; you can retry in Settings." ;;
esac

say ""
say "Installed: $APP"
say ""
say "Look at the top right of your screen: there is a new sparkle icon."
say "Click it to see how much junk this Mac is carrying, and clean it in one go."
say ""
say "First look at this Mac, from here:"
say ""
"$APP/Contents/MacOS/JustCleaner" scan || true
say "Full explanation of everything found:"
say "  $APP/Contents/MacOS/JustCleaner report --open"
say ""
