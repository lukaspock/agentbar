#!/bin/bash
# Builds the `agentbar` CLI and the `agentbar-host` binary (SwiftPM products) and places them in the app bundle:
#   Resources/agentbar                    - where HookSetup.locateCLI() looks for it
#   Resources/AgentSetup/                 - admin-installer payload: agentbar, agentbar-host, setup-agent-user.sh,
#                                           com.agentbar.host.plist.template and manifest.json (SHA-256 of each file)
# Binaries are signed ad-hoc (nested code must be signed before the app is sealed); the manifest is written AFTER
# signing so the hashes match the final bytes. AdminInstaller copies this folder into a root-owned staging dir and
# re-verifies every hash there before anything is executed as root.
set -euo pipefail
PKG="$SRCROOT/../Packages/AgentBarCore"
SCRIPTS="$SRCROOT/../Scripts"
CFG=debug; [ "${CONFIGURATION:-Debug}" = "Release" ] && CFG=release
SCRATCH="$DERIVED_FILE_DIR/agentbar-spm"
# Keep Xcode's compiler/SDK environment out of the nested SwiftPM build.
for product in agentbar agentbar-host; do
  env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(xcrun -f swift)")" \
    DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}" \
    swift build -c "$CFG" --product "$product" --package-path "$PKG" --scratch-path "$SCRATCH" -Xswiftc -warnings-as-errors >&2
done
DEST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Resources"
PAYLOAD="$DEST/AgentSetup"
mkdir -p "$DEST"
rm -rf "$PAYLOAD"; mkdir -p "$PAYLOAD"
install -m 755 "$SCRATCH/$CFG/agentbar" "$DEST/agentbar"
install -m 755 "$SCRATCH/$CFG/agentbar" "$PAYLOAD/agentbar"
install -m 755 "$SCRATCH/$CFG/agentbar-host" "$PAYLOAD/agentbar-host"
install -m 755 "$SCRIPTS/setup-agent-user.sh" "$PAYLOAD/setup-agent-user.sh"
install -m 644 "$SCRIPTS/com.agentbar.host.plist.template" "$PAYLOAD/com.agentbar.host.plist.template"
for f in "$DEST/agentbar" "$PAYLOAD/agentbar" "$PAYLOAD/agentbar-host"; do
  codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" --timestamp=none "$f"
done
# Manifest: {"version":1,"files":{"<name>":"<sha256 hex>",...}} - names are fixed, flat, no paths.
{
  printf '{"version":1,"files":{'
  sep=""
  for name in agentbar agentbar-host setup-agent-user.sh com.agentbar.host.plist.template; do
    printf '%s"%s":"%s"' "$sep" "$name" "$(shasum -a 256 "$PAYLOAD/$name" | awk '{print $1}')"
    sep=","
  done
  printf '}}\n'
} > "$PAYLOAD/manifest.json"
chmod 644 "$PAYLOAD/manifest.json"
echo "agentbar + agentbar-host bundled at $DEST (AgentSetup/manifest.json written)"
