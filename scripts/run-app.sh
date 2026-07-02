#!/usr/bin/env bash
#
# run-app.sh — build (optional) and launch AniCompanion for manual testing.
#
# Usage:
#   ./scripts/run-app.sh              # launch the built app (builds first if none is found)
#   ./scripts/run-app.sh --build      # always rebuild first, then launch
#   ./scripts/run-app.sh -b           # short for --build
#   ./scripts/run-app.sh --quit       # quit any running instance first, then launch fresh
#   ./scripts/run-app.sh -b --quit    # rebuild, quit the old instance, launch the new one
#
# Notes:
#   * The app always starts in the normal window (Desktop Pet mode isn't persisted —
#     toggle it with the 🐾 button, the Character menu, or ⌘⇧D).
#   * macOS `open` re-focuses an already-running instance instead of starting fresh, so
#     use --quit when you want to be sure you're running the build you just made.
#
set -euo pipefail

# Resolve repo root from this script's location (works when run from anywhere).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="AniCompanion"
PROJECT="AniCompanion.xcodeproj"

DO_BUILD=0
DO_QUIT=0

for arg in "$@"; do
  case "$arg" in
    -b|--build) DO_BUILD=1 ;;
    --quit)     DO_QUIT=1 ;;
    -h|--help)  grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

# The .xcodeproj is gitignored (XcodeGen owns it) — generate it if missing.
if [[ ! -d "$PROJECT" ]]; then
  echo "→ $PROJECT missing; running xcodegen generate"
  xcodegen generate
fi

# Locate the built .app from the real build settings (survives DerivedData hash changes).
built_app_path() {
  local settings dir name
  settings="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Debug \
              -showBuildSettings 2>/dev/null)" || return 1
  dir="$(awk -F' = ' '/ TARGET_BUILD_DIR = /{print $2; exit}' <<<"$settings")"
  name="$(awk -F' = ' '/ FULL_PRODUCT_NAME = /{print $2; exit}' <<<"$settings")"
  [[ -n "$dir" && -n "$name" ]] && echo "$dir/$name"
}

APP="$(built_app_path || true)"

if [[ "$DO_BUILD" == "1" || -z "${APP:-}" || ! -d "${APP:-/nonexistent}" ]]; then
  echo "→ Building $SCHEME (Debug)…"
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=macOS' -configuration Debug build | tail -1
  APP="$(built_app_path)"
fi

if [[ -z "${APP:-}" || ! -d "$APP" ]]; then
  echo "✗ Could not locate the built app. Try: ./scripts/run-app.sh --build" >&2
  exit 1
fi
echo "→ App: $APP"

# Quit a running instance if asked, so `open` launches the fresh build rather than
# re-focusing whatever was already up.
if [[ "$DO_QUIT" == "1" ]]; then
  echo "→ Quitting any running instance…"
  osascript -e 'quit app "AniCompanion"' >/dev/null 2>&1 || true
  sleep 1
  pkill -f 'AniCompanion.app' >/dev/null 2>&1 || true
  sleep 1
fi

echo "→ Launching…"
open "$APP"
