#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "$ROOT/.test-stage.XXXXXX")"
TEST_DIR="$(cd "$TEST_DIR" && pwd -P)"
FIXTURE_HOME="$(mktemp -d "$HOME/.mactidy-test.XXXXXX")"
trap 'rm -rf "$TEST_DIR" "$FIXTURE_HOME"' EXIT
# A compiled fixture home keeps every test away from the user's data.
python3 - "$ROOT" "$TEST_DIR" <<'PY'
from pathlib import Path
import sys
root, dest = map(Path, sys.argv[1:])
s = (root/'Sources/Core/Paths.swift').read_text()
s = s.replace('static let home = NSHomeDirectory()', 'static let home = ProcessInfo.processInfo.environment["MACTIDY_FIXTURE_HOME"]!')
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
MACTIDY_FIXTURE_HOME="$FIXTURE_HOME" "$TEST_DIR/tests"
