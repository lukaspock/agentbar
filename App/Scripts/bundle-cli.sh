#!/bin/bash
# Builds the `agentbar` CLI (SwiftPM product) and places it at AgentBar.app/Contents/Resources/agentbar,
# where HookSetup.locateCLI() looks for it. Signed ad-hoc (nested code must be signed before the app is sealed).
set -euo pipefail
PKG="$SRCROOT/../Packages/AgentBarCore"
CFG=debug; [ "${CONFIGURATION:-Debug}" = "Release" ] && CFG=release
SCRATCH="$DERIVED_FILE_DIR/agentbar-spm"
# Keep Xcode's compiler/SDK environment out of the nested SwiftPM build.
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(xcrun -f swift)")" \
  DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
  swift build -c "$CFG" --product agentbar --package-path "$PKG" --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors >&2
BIN="$SCRATCH/$CFG/agentbar"
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
mkdir -p "$DEST"
install -m 755 "$BIN" "$DEST/agentbar"
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$DEST/agentbar"
echo "agentbar bundled at $DEST/agentbar"
