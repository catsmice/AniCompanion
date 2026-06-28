#!/usr/bin/env bash
#
# Downloads the default VRM character model (Alicia Solid / ニコニ立体ちゃん) into
# AniCompanion/Resources/VRMModel/ so the app has a character to render.
#
# The model is NOT committed to this repository and is NOT bundled in any release: its
# license (Dwango's terms, not MIT) does NOT permit redistributing the original model file.
# This script is a convenience that downloads the model for YOUR OWN local use; by running
# it you take responsibility for complying with Dwango's terms. See
# AniCompanion/Resources/VRMModel/LICENSE-AliciaSolid.md for the full summary.
#
# Alicia Solid © DWANGO Co., Ltd.  License: https://3d.nicovideo.jp/alicia/rule.html
# (Redistribution: not permitted. Commercial use: individuals/non-corporate only.)
# Official download: https://3d.nicovideo.jp/alicia/
#
# Usage:  ./scripts/download-model.sh
#
set -euo pipefail

# Resolve repo root from this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

DEST_DIR="$REPO_ROOT/AniCompanion/Resources/VRMModel"
DEST_FILE="$DEST_DIR/AliciaSolid.vrm"

# Canonical, stable copy bundled as a test asset in the official UniVRM repo.
MODEL_URL="https://raw.githubusercontent.com/vrm-c/UniVRM/master/Tests/Models/Alicia_vrm-0.51/AliciaSolid_vrm-0.51.vrm"

mkdir -p "$DEST_DIR"

if [[ -f "$DEST_FILE" ]]; then
    echo "Model already present: $DEST_FILE"
    echo "Delete it first if you want to re-download."
    exit 0
fi

echo "Downloading Alicia Solid VRM..."
echo "  from: $MODEL_URL"
echo "  to:   $DEST_FILE"
curl -fL --retry 3 --max-time 120 -o "$DEST_FILE" "$MODEL_URL"

# Sanity check: VRM files are glTF binaries beginning with the "glTF" magic.
if [[ "$(head -c 4 "$DEST_FILE")" != "glTF" ]]; then
    echo "ERROR: downloaded file is not a valid glTF/VRM binary." >&2
    rm -f "$DEST_FILE"
    exit 1
fi

echo "Done. Model saved to $DEST_FILE"
