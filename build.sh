#!/usr/bin/env bash
#
# Build script for Online Status.
#
# Usage: ./build.sh [command]
#
# Commands:
#   build     Build a Release OnlineStatus.app into build/ (default)
#   debug     Build a Debug OnlineStatus.app into build/
#   test      Run the unit tests
#   screenshots  Render README screenshots into docs/screenshots/
#             (override with SCREENSHOT_DIR=path)
#   run       Build (Debug) and launch the app
#   install   Build (Release) and copy OnlineStatus.app to ~/Applications
#   dist      Build (Release) and package build/OnlineStatus-<version>.zip
#   clean     Remove build output
#
# Signing:
#   By default the app is ad-hoc signed ("-"), which is fine for running
#   locally. To sign with your Apple Developer identity, set:
#     CODE_SIGN_IDENTITY="Developer ID Application: Your Name (ABCDE12345)" ./build.sh build
#
# Architectures:
#   Builds for this Mac's architecture. For arm64 + x86_64, set UNIVERSAL=1.

set -euo pipefail

cd "$(dirname "$0")"

PRODUCT="OnlineStatus"
APP_NAME="OnlineStatus"
BUILD_DIR="build"
SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"

ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == 1 ]]; then
    ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }

check_swift() {
    if ! command -v swift >/dev/null 2>&1; then
        echo "error: swift not found; install Xcode 15 or later." >&2
        exit 1
    fi
}

# swift build with the architecture flags (safe when the array is empty on bash 3.2).
swiftbuild() {
    check_swift
    swift build ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} "$@"
}

# Builds the given configuration (release or debug) and assembles a signed .app in build/.
build_app() {
    local config="$1"
    log "Building $APP_NAME ($config)"
    swiftbuild -c "$config"
    local bin_path
    bin_path="$(swiftbuild -c "$config" --show-bin-path)"

    local app="$BUILD_DIR/$APP_NAME.app"
    rm -rf "$app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$bin_path/$PRODUCT" "$app/Contents/MacOS/$PRODUCT"
    cp App/Info.plist "$app/Contents/Info.plist"

    log "Signing with identity \"$SIGN_IDENTITY\""
    codesign --force --options runtime \
        --entitlements App/OnlineStatus.entitlements \
        --sign "$SIGN_IDENTITY" \
        "$app"
    log "Built $app"
}

app_version() {
    /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
        "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist"
}

quit_running_app() {
    if pgrep -x "$PRODUCT" >/dev/null; then
        log "Quitting running $APP_NAME"
        osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || pkill -x "$PRODUCT" || true
        sleep 1
    fi
}

cmd="${1:-build}"
case "$cmd" in
    build)
        build_app release
        ;;
    debug)
        build_app debug
        ;;
    test)
        log "Running tests"
        check_swift
        swift test
        ;;
    screenshots)
        out="${SCREENSHOT_DIR:-docs/screenshots}"
        mkdir -p "$out"
        out="$(cd "$out" && pwd)"
        log "Rendering screenshots into $out"
        # The plain executable (not the sandboxed .app) so it can write anywhere.
        swiftbuild -c debug
        "$(swiftbuild -c debug --show-bin-path)/$PRODUCT" --screenshots "$out"
        ls -1 "$out"
        ;;
    run)
        build_app debug
        quit_running_app
        log "Launching $APP_NAME"
        open "$BUILD_DIR/$APP_NAME.app"
        ;;
    install)
        build_app release
        quit_running_app
        dest="$HOME/Applications"
        mkdir -p "$dest"
        rm -rf "${dest:?}/$APP_NAME.app"
        cp -R "$BUILD_DIR/$APP_NAME.app" "$dest/"
        log "Installed to $dest/$APP_NAME.app"
        ;;
    dist)
        build_app release
        zip="$BUILD_DIR/$APP_NAME-$(app_version).zip"
        rm -f "$zip"
        ditto -c -k --keepParent "$BUILD_DIR/$APP_NAME.app" "$zip"
        log "Packaged $zip"
        ;;
    clean)
        log "Removing $BUILD_DIR/ and .build/"
        rm -rf "$BUILD_DIR" .build
        ;;
    -h|--help|help)
        sed -n '3,25p' "$0" | sed 's/^# \{0,1\}//'
        ;;
    *)
        echo "Unknown command: $cmd" >&2
        echo "Run '$0 help' for usage." >&2
        exit 1
        ;;
esac
