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

mkdir -p "$(dirname "$OUTPUT_PATH")"
hdiutil create \
    -volname TinyTaskbar \
    -srcfolder "$APP_PATH" \
    -ov \
    -format UDZO \
    "$OUTPUT_PATH"

echo "Created $OUTPUT_PATH"
