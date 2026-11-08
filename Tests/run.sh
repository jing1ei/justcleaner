#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "$ROOT/.test-stage.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
FIXTURE_HOME="$(mktemp -d "$HOME/.justcleaner-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_HOME"' EXIT

# Pick a usable SDK: the default SDK can be newer than the installed compiler
# after a macOS upgrade, which would make even a trivial compile fail.
if [ -z "${SDKROOT:-}" ]; then
  PROBE="$(mktemp "${TMPDIR:-/tmp}/justcleaner-sdkprobe.XXXXXX")"
  printf 'import Foundation\n' > "$PROBE.swift"
  for candidate in "$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" \
                   $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk 2>/dev/null | sort -Vr); do
    [ -d "$candidate" ] || continue
    if SDKROOT="$candidate" swiftc -target arm64-apple-macosx11.0 \
         -o "$PROBE" "$PROBE.swift" >/dev/null 2>&1; then
      export SDKROOT="$candidate"
      break
    fi
  done
  rm -f "$PROBE" "$PROBE.swift"
fi

# A compiled fixture home keeps every test away from the user's data.
python3 - "$ROOT" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, dest = map(Path, sys.argv[1:])
s = (root/'Sources/Core/Paths.swift').read_text()
s = s.replace('static let home = NSHomeDirectory()', 'static let home = ProcessInfo.processInfo.environment["JUSTCLEANER_FIXTURE_HOME"]!')
(dest/'Paths.swift').write_text(s)
# Expose controller internals only in the test copy for AppKit state tests.
(dest/'MenuController.swift').write_text((root/'Sources/App/MenuController.swift').read_text().replace('private ', ''))
PY
SOURCES=("$TEST_DIR/Paths.swift" "$TEST_DIR/MenuController.swift")
for file in "$ROOT"/Sources/Core/*.swift "$ROOT"/Sources/App/*.swift; do
  case "$file" in */Paths.swift|*/MenuController.swift|*/main.swift) continue ;; esac
  SOURCES+=("$file")
done
cp "$ROOT/Tests/main.swift" "$TEST_DIR/main.swift"
swiftc -swift-version 5 -framework AppKit -o "$TEST_DIR/tests" "${SOURCES[@]}" "$TEST_DIR/main.swift"
JUSTCLEANER_FIXTURE_HOME="$FIXTURE_HOME" "$TEST_DIR/tests"
