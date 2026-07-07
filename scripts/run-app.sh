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

# Optional stable dev signing (see CONTRIBUTING.md → "Testing screen vision"): if
# scripts/dev-signing-identity exists (gitignored; contains a codesign identity name or SHA-1
# hash), re-sign the build with it so signature-bound TCC grants (Screen Recording — used by
# screen vision AND live transcription) survive rebuilds. Without it, ad-hoc-signed builds lose
# the grant on every rebuild. Idempotent and fast, so it runs on every launch.
IDENTITY_FILE="$SCRIPT_DIR/dev-signing-identity"
if [[ -f "$IDENTITY_FILE" ]]; then
  IDENTITY="$(head -1 "$IDENTITY_FILE" | tr -d '[:space:]')"
  if [[ -n "$IDENTITY" ]]; then
    echo "→ Re-signing with dev identity ($IDENTITY)…"
    codesign --force --deep --sign "$IDENTITY" \
      --entitlements "$REPO_ROOT/AniCompanion/AniCompanion.entitlements" \
      --timestamp=none "$APP" \
      || echo "⚠ Re-sign failed — launching the build as-is (TCC grants may not stick)" >&2
  fi
fi

# Quit a running instance if asked, so `open` launches the fresh build rather than
# re-focusing whatever was already up.
if [[ "$DO_QUIT" == "1" ]]; then
  echo "→ Quitting any running instance…"
  osascript -e 'quit app "AniCompanion"' >/dev/null 2>&1 || true
  sleep 1
  pkill -f 'AniCompanion.app' >/dev/null 2>&1 || true
  sleep 1
fi

# Re-register THIS build with LaunchServices before launching. If another copy of the app with the
# same bundle id is registered (a second checkout, an installed build, or a stale DerivedData path),
# `open` can resolve the bundle id to that other copy and launch the wrong one — or nothing that
# stays running. Force-registering our exact path makes `open` launch the build we just built.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP" >/dev/null 2>&1 || true

echo "→ Launching…"
open "$APP"
