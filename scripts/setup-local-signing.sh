#!/bin/bash
set -euo pipefail

IDENTITY_NAME="${TINYTASKBAR_LOCAL_SIGNING_IDENTITY:-TinyTaskbar Local Development}"
KEYCHAIN_PATH="$(
    security default-keychain -d user \
        | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
)"

if [[ -z "$KEYCHAIN_PATH" || ! -f "$KEYCHAIN_PATH" ]]; then
    echo "Could not resolve the user's default keychain." >&2
    exit 1
fi

if security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "Local signing identity already exists: $IDENTITY_NAME"
    exit 0
fi

if security find-certificate -c "$IDENTITY_NAME" "$KEYCHAIN_PATH" >/dev/null 2>&1; then
    echo "A certificate named '$IDENTITY_NAME' exists without a usable private key." >&2
    echo "Remove or repair that keychain item before running this setup again." >&2
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tinytaskbar-signing.XXXXXX")"
PRIVATE_KEY="$TEMP_DIR/private-key.pem"
CERTIFICATE="$TEMP_DIR/certificate.pem"

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

umask 077
openssl genrsa -out "$PRIVATE_KEY" 3072
openssl req \
    -new \
    -x509 \
    -key "$PRIVATE_KEY" \
    -sha256 \
    -days 3650 \
    -out "$CERTIFICATE" \
    -subj "/CN=$IDENTITY_NAME/O=TinyTaskbar Local Development" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,keyCertSign" \
    -addext "extendedKeyUsage=codeSigning"

security import "$PRIVATE_KEY" \
    -k "$KEYCHAIN_PATH" \
    -t priv \
    -f openssl \
    -T /usr/bin/codesign
security add-trusted-cert \
    -r trustRoot \
    -p codeSign \
    -k "$KEYCHAIN_PATH" \
    "$CERTIFICATE"

if ! security find-identity -v -p codesigning "$KEYCHAIN_PATH" \
    | grep -Fq "\"$IDENTITY_NAME\""; then
    echo "The imported certificate is not available as a code-signing identity." >&2
    exit 1
fi

echo "Created local signing identity: $IDENTITY_NAME"
echo "Stored in: $KEYCHAIN_PATH"
echo "This identity is for local development only; do not use it for distribution."
