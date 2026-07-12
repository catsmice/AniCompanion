#!/usr/bin/env bash
#
# build-dmg.sh — build a Developer-ID-signed, notarized, stapled .dmg of AniCompanion.
#
# Produces a distributable disk image that opens cleanly on any Mac (no "unidentified
# developer" / Gatekeeper warning). Run locally; later wrapped by the release CI.
#
# Prerequisites (one-time, already set up):
#   * "Developer ID Application" cert in the login keychain.
#   * A notarytool keychain profile with your Apple ID + app-specific password:
#       xcrun notarytool store-credentials "AniCompanion" --apple-id <id> --team-id <team>
#
# Usage:
#   ./scripts/build-dmg.sh            # build → sign → notarize → staple → verify
#   ./scripts/build-dmg.sh --skip-build   # reuse the last Release build (faster re-runs)
#
set -euo pipefail

# ---- Config -----------------------------------------------------------------
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: CHI MIN LEE (3J73HR57J5)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-AniCompanion}"
SCHEME="AniCompanion"
PROJECT="AniCompanion.xcodeproj"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

DERIVED="$REPO_ROOT/.build-release"
ENTITLEMENTS="$REPO_ROOT/AniCompanion/AniCompanion.entitlements"

SKIP_BUILD=0
[[ "${1:-}" == "--skip-build" ]] && SKIP_BUILD=1

step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }

# ---- 0. Preflight -----------------------------------------------------------
step "Preflight"
security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
  || { echo "✗ Signing identity not found: $SIGN_IDENTITY"; exit 1; }
xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
  || { echo "✗ notarytool profile '$NOTARY_PROFILE' not usable (store-credentials first)"; exit 1; }
[[ -d "$PROJECT" ]] || xcodegen generate
echo "✓ identity, notary profile, project all present"

# ---- 1. Build (Release) -----------------------------------------------------
if [[ "$SKIP_BUILD" == "0" ]]; then
  step "Building $SCHEME (Release)"
  # Build with the project's default (ad-hoc) signing, then re-sign with Developer ID below —
  # same pattern as run-app.sh. Re-signing replaces whatever the build produced.
  xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -derivedDataPath "$DERIVED" -destination 'platform=macOS' \
    clean build | tail -1
fi

APP="$DERIVED/Build/Products/Release/AniCompanion.app"
[[ -d "$APP" ]] || { echo "✗ Built app not found at $APP (drop --skip-build)"; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
echo "✓ App: $APP  (v$VERSION)"

# ---- 2. Sign (Developer ID + hardened runtime + secure timestamp) -----------
step "Signing with Developer ID (hardened runtime, timestamp)"
# No embedded frameworks/helpers, but sign deep + the main bundle to be safe.
codesign --force --deep --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "✓ signed + signature verifies"

# ---- 4. Notarize the app, then staple it (so it validates OFFLINE too) ------
step "Notarizing the app (uploading to Apple — this can take a few minutes)"
APP_ZIP="$(mktemp -d)/AniCompanion.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"      # notarytool takes a zip/dmg/pkg, not a bare .app
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$APP_ZIP"

step "Stapling the ticket onto the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
echo "✓ app is notarized + stapled (offline-trusted)"

# ---- 5. Package the .dmg from the stapled app, notarize + staple the dmg -----
step "Building disk image"
DMG="$REPO_ROOT/AniCompanion-$VERSION.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"                          # the stapled app
ln -s /Applications "$STAGING/Applications"       # drag-to-install target
rm -f "$DMG"
hdiutil create -volname "AniCompanion $VERSION" -srcfolder "$STAGING" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"
echo "✓ $DMG"

step "Notarizing + stapling the disk image (clean mount from a download)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# ---- 6. Verify the app inside the dmg the way Gatekeeper actually sees it ----
step "Gatekeeper verification (assessing the app inside the dmg)"
MP="$(hdiutil attach "$DMG" -nobrowse -readonly | grep -o '/Volumes/.*' | head -1)"
spctl -a -vvv -t exec "$MP/AniCompanion.app" 2>&1 || true
hdiutil detach "$MP" >/dev/null 2>&1 || true

printf '\n\033[1;32m✓ Done: %s\033[0m\n' "$DMG"
echo "  App + DMG both notarized & stapled — opens cleanly on any Mac, even offline."
