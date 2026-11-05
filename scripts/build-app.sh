#!/bin/bash
# Builds build/OnlineStatus.app with SwiftPM and signs it (ad-hoc by default).
#
#   scripts/build-app.sh                 # native architecture, ad-hoc signed
#   UNIVERSAL=1 scripts/build-app.sh     # arm64 + x86_64
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -euo pipefail

cd "$(dirname "$0")/.."

arch_flags=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
  arch_flags=(--arch arm64 --arch x86_64)
fi

swift build -c release ${arch_flags[@]+"${arch_flags[@]}"}
bin_path="$(swift build -c release ${arch_flags[@]+"${arch_flags[@]}"} --show-bin-path)"

app="build/OnlineStatus.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_path/OnlineStatus" "$app/Contents/MacOS/OnlineStatus"
cp App/Info.plist "$app/Contents/Info.plist"

codesign --force --options runtime \
  --entitlements App/OnlineStatus.entitlements \
  --sign "${SIGN_IDENTITY:--}" \
  "$app"

echo "Built $app"
