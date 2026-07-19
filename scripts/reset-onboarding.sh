#!/usr/bin/env bash
#
# reset-onboarding.sh — reset AniCompanion to a first-run state so the setup wizard shows again,
# or restore your real settings afterward. For manually testing the first-launch experience.
#
# Usage:
#   ./scripts/reset-onboarding.sh            # back up, then clear onboarding + chat connections
#   ./scripts/reset-onboarding.sh --restore  # restore the most recent backup this script made
#   ./scripts/reset-onboarding.sh --help
#
# Why this is fiddly (two macOS traps this script works around):
#   1. Leftover sandbox container: `defaults read/write com.anicompanion.app` silently redirects to
#      ~/Library/Containers/..., which the (non-sandboxed) app never reads. So we edit the GLOBAL
#      plist directly with PlistBuddy, and delete the stale container plist.
#   2. cfprefsd cache + graceful-quit flush: a gracefully-quit app flushes its in-memory UserDefaults
#      back to disk, and cfprefsd serves its cache to the app on the next launch (ignoring our disk
#      edit). So we SIGKILL the app (no flush) and `killall cfprefsd` around the edit, with no pref
#      reads in between, so the next launch reads our edited file.
#
# After a reset, launch with ./scripts/run-app.sh --quit and the wizard should appear.
#
set -euo pipefail

BUNDLE_ID="com.anicompanion.app"
# The running process's command line is …/AniCompanion.app/Contents/MacOS/AniCompanion — it contains
# the app-bundle name, NOT the bundle id — so pkill must match on this, not on $BUNDLE_ID.
APP_PROCESS_MATCH="AniCompanion.app"
GLOBAL_PLIST="$HOME/Library/Preferences/$BUNDLE_ID.plist"
CONTAINER_PLIST="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Preferences/$BUNDLE_ID.plist"
BACKUP_DIR="$HOME/Library/Preferences"
BACKUP_GLOB="$BACKUP_DIR/$BUNDLE_ID.plist.onboarding-bak-"

# The keys that gate the first-run wizard: the completion flag, the selected backend, and every
# per-backend + legacy connection key (any non-empty one makes `hasConfiguredBackend` true).
KEYS=(
  agent_setup_completed
  chat_backend
  chat_endpoint chat_api_key hermes_endpoint hermes_api_key
  chat_endpoint_hermes chat_api_key_hermes
  chat_endpoint_openAICompatible chat_api_key_openAICompatible
  chat_endpoint_claudeCode chat_api_key_claudeCode
  chat_endpoint_codex chat_api_key_codex
  chat_endpoint_gemini chat_api_key_gemini
)

case "${1:-}" in
  -h|--help) grep '^#' "$0" | grep -v '^#!' | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# Always: force-kill the app (SIGKILL — no graceful UserDefaults flush) and drop cfprefsd's cache.
kill_app_and_daemon() {
  if pkill -9 -f "$APP_PROCESS_MATCH" 2>/dev/null; then echo "→ Force-killed running app (no defaults flush)"; fi
  sleep 1
  killall cfprefsd 2>/dev/null || true
  sleep 1
}

if [[ "${1:-}" == "--restore" ]]; then
  latest="$(ls -t "${BACKUP_GLOB}"* 2>/dev/null | head -1 || true)"
  if [[ -z "$latest" ]]; then
    echo "✗ No backup found (${BACKUP_GLOB}*). Nothing to restore." >&2
    exit 1
  fi
  echo "→ Restoring: $latest"
  kill_app_and_daemon
  cp "$latest" "$GLOBAL_PLIST"
  killall cfprefsd 2>/dev/null || true
  echo "✅ Restored. agent_setup_completed = $(/usr/libexec/PlistBuddy -c 'Print :agent_setup_completed' "$GLOBAL_PLIST" 2>/dev/null || echo absent), chat_backend = $(/usr/libexec/PlistBuddy -c 'Print :chat_backend' "$GLOBAL_PLIST" 2>/dev/null || echo absent)"
  exit 0
fi

# --- Reset path ---

if [[ ! -f "$GLOBAL_PLIST" ]]; then
  echo "✗ No prefs found at $GLOBAL_PLIST — the app is already in a fresh state." >&2
  exit 0
fi

# 1. Back up the current global plist (timestamped, next to it — restore with --restore).
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="${BACKUP_GLOB}${STAMP}.plist"
cp "$GLOBAL_PLIST" "$BACKUP"
echo "→ Backed up to: $BACKUP"

# 2. SIGKILL app + drop cfprefsd cache BEFORE editing.
kill_app_and_daemon

# 3. Delete the onboarding + connection keys directly in the global plist (bypass `defaults`).
deleted=0
for k in "${KEYS[@]}"; do
  if /usr/libexec/PlistBuddy -c "Delete :$k" "$GLOBAL_PLIST" 2>/dev/null; then
    deleted=$((deleted + 1))
  fi
done
echo "→ Deleted $deleted onboarding/connection key(s) from the global plist"

# Remove the stale sandbox-container plist so `defaults`/cfprefsd stop redirecting there.
if [[ -f "$CONTAINER_PLIST" ]]; then
  rm -f "$CONTAINER_PLIST" && echo "→ Removed stale container plist"
fi

# 4. Drop cfprefsd cache again so the next launch reads our edited file (not stale cache).
killall cfprefsd 2>/dev/null || true
sleep 1

# 5. Verify.
echo "→ Verifying…"
if /usr/libexec/PlistBuddy -c "Print" "$GLOBAL_PLIST" 2>/dev/null | grep -qiE 'chat_backend|agent_setup|chat_endpoint_|chat_api_key_'; then
  echo "⚠ Some keys are still present — a running app may have re-flushed them. Make sure the app is fully quit and re-run." >&2
else
  echo "✅ Clean fresh-install state (your TTS/STT keys, language, etc. were preserved)."
fi

echo
echo "Next:  ./scripts/run-app.sh --quit    # the setup wizard should appear on launch"
echo "Undo:  ./scripts/reset-onboarding.sh --restore"
