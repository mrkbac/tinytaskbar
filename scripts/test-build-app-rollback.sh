#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tinytaskbar-build-rollback.XXXXXX")"
OUTPUT_APP="$TEST_ROOT/TinyTaskbar-Rollback-Test.app"
SENTINEL="$OUTPUT_APP/Contents/Resources/previous-bundle-sentinel.txt"

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

bash "$SCRIPT_DIR/build-app.sh" \
    --adhoc \
    --configuration release \
    --output "$OUTPUT_APP"
INTENTS_METADATA="$OUTPUT_APP/Contents/Resources/Metadata.appintents/extract.actionsdata"
if [[ ! -s "$INTENTS_METADATA" ]]; then
    echo "Built bundle is missing App Intents metadata" >&2
    exit 1
fi
if [[ "$(plutil -extract actions.MinimizeAllWindowsIntent.title.key raw "$INTENTS_METADATA")" != "Minimize All Windows" ]]; then
    echo "Built bundle is missing the Minimize All Windows intent" >&2
    exit 1
fi
touch "$SENTINEL"
codesign --force --deep --sign - "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

if TINYTASKBAR_BUILD_TEST_FAIL_AFTER_REPLACE=1 \
    bash "$SCRIPT_DIR/build-app.sh" \
        --adhoc \
        --configuration release \
        --output "$OUTPUT_APP"
then
    echo "Expected the injected final verification failure" >&2
    exit 1
fi

if [[ ! -f "$SENTINEL" ]]; then
    echo "Previous bundle was not restored after final verification failure" >&2
    exit 1
fi
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"

echo "Rollback restored the previous bundle"

rm -rf "$OUTPUT_APP"
if TINYTASKBAR_BUILD_TEST_FAIL_AFTER_REPLACE=1 \
    bash "$SCRIPT_DIR/build-app.sh" \
        --adhoc \
        --configuration release \
        --output "$OUTPUT_APP"
then
    echo "Expected the injected final verification failure without a previous bundle" >&2
    exit 1
fi

if [[ -e "$OUTPUT_APP" || -L "$OUTPUT_APP" ]]; then
    echo "Failed replacement survived without a previous bundle" >&2
    exit 1
fi

echo "Rollback removed the failed bundle when no previous bundle existed"
