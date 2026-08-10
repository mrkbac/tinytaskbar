#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$PROJECT_DIR/Resources/Info.plist"
ENTITLEMENTS="$PROJECT_DIR/Resources/TinyTaskbar.entitlements"
APP_ICON="$PROJECT_DIR/Resources/AppIcon.icns"
DIST_DIR="$PROJECT_DIR/dist"

usage() {
    echo "Usage: $0 [--local | --adhoc | --identity <Developer ID Application identity>] [--configuration debug|release] [--output <app path>]" >&2
}

SIGNING_MODE=""
SIGNING_IDENTITY=""
LOCAL_SIGNING_IDENTITY="${TINYTASKBAR_LOCAL_SIGNING_IDENTITY:-TinyTaskbar Local Development}"
OUTPUT_APP=""
CONFIGURATION="release"

while (($# > 0)); do
    case "$1" in
        --local)
            SIGNING_MODE="local"
            SIGNING_IDENTITY="$LOCAL_SIGNING_IDENTITY"
            shift
            ;;
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
    SIGNING_MODE="local"
    SIGNING_IDENTITY="$LOCAL_SIGNING_IDENTITY"
fi

if [[ ! -f "$INFO_PLIST" || ! -f "$ENTITLEMENTS" || ! -f "$APP_ICON" ]]; then
    echo "Missing bundle resources under $PROJECT_DIR/Resources" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
if [[ -z "$OUTPUT_APP" ]]; then
    OUTPUT_APP="$DIST_DIR/TinyTaskbar.app"
fi
if [[ "$OUTPUT_APP" != *.app ]]; then
    echo "Output path must end in .app: $OUTPUT_APP" >&2
    exit 2
fi

swift build -c "$CONFIGURATION" --product TinyTaskbar
BIN_PATH="$(swift build -c "$CONFIGURATION" --product TinyTaskbar --show-bin-path)"
EXECUTABLE="$BIN_PATH/TinyTaskbar"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "$CONFIGURATION executable was not produced at $EXECUTABLE" >&2
    exit 1
fi

OUTPUT_PARENT="$(dirname "$OUTPUT_APP")"
mkdir -p "$OUTPUT_PARENT"
STAGING_DIR="$(mktemp -d "$OUTPUT_PARENT/.tinytaskbar-build.XXXXXX")"
STAGED_APP="$STAGING_DIR/TinyTaskbar.app"
PREVIOUS_APP="$STAGING_DIR/previous.app"
FAILED_APP="$STAGING_DIR/failed.app"
REPLACEMENT_STARTED=false
REPLACEMENT_COMMITTED=false
cleanup() {
    local exit_status=$?
    local rollback_failed=false
    local previous_available=false

    if [[ -e "$PREVIOUS_APP" || -L "$PREVIOUS_APP" ]]; then
        previous_available=true
    fi
    if [[ "$REPLACEMENT_COMMITTED" != true && ( "$REPLACEMENT_STARTED" == true || "$previous_available" == true ) ]]; then
        if [[ -e "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
            if ! mv "$OUTPUT_APP" "$FAILED_APP"; then
                echo "Could not quarantine failed bundle at $OUTPUT_APP" >&2
                rollback_failed=true
            fi
        fi
        if [[ "$previous_available" == true ]]; then
            if [[ ! -e "$OUTPUT_APP" && ! -L "$OUTPUT_APP" ]]; then
                if ! mv "$PREVIOUS_APP" "$OUTPUT_APP"; then
                    echo "Could not restore previous bundle at $OUTPUT_APP" >&2
                    rollback_failed=true
                fi
            else
                echo "Could not restore previous bundle because destination is occupied: $OUTPUT_APP" >&2
                rollback_failed=true
            fi
        fi
    fi

    if [[ "$rollback_failed" == true ]]; then
        echo "Preserved recovery artifacts at $STAGING_DIR" >&2
    else
        rm -rf "$STAGING_DIR"
    fi
    return "$exit_status"
}
trap cleanup EXIT

CONTENTS="$STAGED_APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
mkdir -p "$MACOS" "$RESOURCES"
cp "$EXECUTABLE" "$MACOS/TinyTaskbar"
cp "$INFO_PLIST" "$CONTENTS/Info.plist"
cp "$APP_ICON" "$RESOURCES/AppIcon.icns"

if [[ "$SIGNING_MODE" == "adhoc" ]]; then
    codesign --force --deep --sign - "$STAGED_APP"
elif [[ "$SIGNING_MODE" == "local" ]]; then
    if ! security find-identity -v -p codesigning \
        | grep -Fq "\"$SIGNING_IDENTITY\""; then
        echo "Local signing identity was not found: $SIGNING_IDENTITY" >&2
        echo "Run: bash scripts/setup-local-signing.sh" >&2
        exit 1
    fi
    codesign \
        --force \
        --options runtime \
        --timestamp=none \
        --entitlements "$ENTITLEMENTS" \
        --sign "$SIGNING_IDENTITY" \
        "$STAGED_APP"
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
        "$STAGED_APP"
fi

codesign --verify --deep --strict --verbose=2 "$STAGED_APP"
plutil -lint "$CONTENTS/Info.plist"

if [[ -e "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
    mv "$OUTPUT_APP" "$PREVIOUS_APP"
fi
REPLACEMENT_STARTED=true
if ! mv "$STAGED_APP" "$OUTPUT_APP"; then
    echo "Could not install assembled bundle at $OUTPUT_APP" >&2
    exit 1
fi

if [[ "${TINYTASKBAR_BUILD_TEST_FAIL_AFTER_REPLACE:-0}" == 1 ]]; then
    echo "Injected final bundle verification failure" >&2
    false
fi
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
plutil -lint "$OUTPUT_APP/Contents/Info.plist"
REPLACEMENT_COMMITTED=true

echo "Built $OUTPUT_APP"
echo "Version $VERSION ($BUILD_NUMBER)"
echo "Signing mode: $SIGNING_MODE"
if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "Signing identity: $SIGNING_IDENTITY"
fi
