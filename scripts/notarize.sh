#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 --profile <notarytool keychain profile> --artifact <app, zip, or dmg> [--staple <path>]" >&2
}

PROFILE=""
ARTIFACT=""
STAPLE_TARGET=""

while (($# > 0)); do
    case "$1" in
        --profile)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            PROFILE="$2"
            shift 2
            ;;
        --artifact)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            ARTIFACT="$2"
            shift 2
            ;;
        --staple)
            [[ $# -ge 2 ]] || { usage; exit 2; }
            STAPLE_TARGET="$2"
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

if [[ -z "$PROFILE" || -z "$ARTIFACT" ]]; then
    usage
    exit 2
fi
if [[ ! -e "$ARTIFACT" ]]; then
    echo "Artifact not found: $ARTIFACT" >&2
    exit 1
fi
if [[ -z "$STAPLE_TARGET" ]]; then
    case "$ARTIFACT" in
        *.zip)
            echo "ZIP submissions require --staple with the original app or DMG path." >&2
            exit 2
            ;;
        *)
            STAPLE_TARGET="$ARTIFACT"
            ;;
    esac
fi
if [[ ! -e "$STAPLE_TARGET" ]]; then
    echo "Staple target not found: $STAPLE_TARGET" >&2
    exit 1
fi

xcrun notarytool submit "$ARTIFACT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$STAPLE_TARGET"
xcrun stapler validate "$STAPLE_TARGET"

case "$STAPLE_TARGET" in
    *.app)
        spctl --assess --type exec --verbose=2 "$STAPLE_TARGET"
        ;;
    *)
        spctl --assess --type open --verbose=2 "$STAPLE_TARGET"
        ;;
esac

echo "Notarized, stapled, and Gatekeeper-validated: $STAPLE_TARGET"
