#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_PATH="$PROJECT_DIR/dist/TinyTaskbar.app"
OUTPUT_PATH="$PROJECT_DIR/dist/TinyTaskbar.dmg"

usage() {
    echo "Usage: $0 [--app <TinyTaskbar.app>] [--output <TinyTaskbar.dmg>]" >&2
}

while (($# > 0)); do
    case "$1" in
        --app)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            APP_PATH="$2"
            shift 2
            ;;
        --output)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            OUTPUT_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if [[ ! -d "$APP_PATH" ]]; then
    echo "App bundle not found: $APP_PATH (run scripts/build-app.sh first)" >&2
    exit 1
fi
if [[ ! -f "$APP_PATH/Contents/Info.plist" ]]; then
    echo "App bundle is missing Contents/Info.plist: $APP_PATH" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"

mkdir -p "$(dirname "$OUTPUT_PATH")"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tinytaskbar-dmg.XXXXXX")"
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

ditto "$APP_PATH" "$STAGING_DIR/TinyTaskbar.app"
codesign --verify --deep --strict --verbose=2 "$STAGING_DIR/TinyTaskbar.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
    -volname TinyTaskbar \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$OUTPUT_PATH"
hdiutil verify "$OUTPUT_PATH"

echo "Created $OUTPUT_PATH"
