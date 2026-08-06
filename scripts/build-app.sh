#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
ENTITLEMENTS="$PROJECT_DIR/Resources/TinyTaskbar.entitlements"
DIST_DIR="$PROJECT_DIR/dist"

usage() {
    echo "Usage: $0 --adhoc | --identity <Developer ID Application identity> [--configuration debug|release] [--output <app path>]" >&2
}

SIGNING_MODE=""
SIGNING_IDENTITY=""
OUTPUT_APP=""
CONFIGURATION="release"

while (($# > 0)); do
    case "$1" in
        --adhoc)
            SIGNING_MODE="adhoc"
            shift
            ;;
        --identity)
            if (($# < 2)); then
                usage
                exit 2
            fi
            SIGNING_MODE="developer-id"
            SIGNING_IDENTITY="$2"
            shift 2
            ;;
        --configuration)
            if (($# < 2)); then
                usage
                exit 2
            fi
            case "$2" in
                debug|release)
                    CONFIGURATION="$2"
                    ;;
                *)
                    echo "Unsupported configuration: $2 (choose debug or release)." >&2
                    usage
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        --output)
            if (($# < 2)); then
                usage
                exit 2
            fi
            OUTPUT_APP="$2"
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

if [[ -z "$SIGNING_MODE" ]]; then
    echo "Choose --adhoc for local verification or --identity for Developer ID signing." >&2
    usage
    exit 2
fi

if [[ ! -f "$INFO_PLIST" || ! -f "$ENTITLEMENTS" ]]; then
    echo "Missing bundle resources under $PROJECT_DIR/Resources" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ -z "$OUTPUT_APP" ]]; then
    OUTPUT_APP="$DIST_DIR/TinyTaskbar.app"
fi

swift build -c "$CONFIGURATION" --product TinyTaskbar
BIN_PATH="$(swift build -c "$CONFIGURATION" --product TinyTaskbar --show-bin-path)"
EXECUTABLE="$BIN_PATH/TinyTaskbar"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "$CONFIGURATION executable was not produced at $EXECUTABLE" >&2
    exit 1
fi

CONTENTS="$OUTPUT_APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RESOURCES"
rm -f "$MACOS/TinyTaskbar"
cp "$EXECUTABLE" "$MACOS/TinyTaskbar"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"

if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    codesign --force --deep --sign - "$OUTPUT_APP"
else
    if ! security find-identity -v -p codesigning | grep -Fq "$SIGNING_IDENTITY"; then
        echo "Developer ID signing identity was not found: $SIGNING_IDENTITY" >&2
        exit 1
    fi
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$OUTPUT_APP"
fi

codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
plutil -lint "$CONTENTS/Info.plist"

echo "Built $OUTPUT_APP"
echo "Version $VERSION ($BUILD_NUMBER)"
echo "Signing mode: $SIGNING_MODE"
