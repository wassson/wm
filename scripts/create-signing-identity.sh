#!/usr/bin/env bash
# Creates a self-signed code-signing identity "wm Local Signing" in your login
# keychain. scripts/bundle.sh picks it up automatically, so every build has the same
# signature and macOS keeps wm's Accessibility permission across updates.
#
# The certificate is only used to sign wm on this Mac. It isn't added to any
# trust settings. Remove it any time in Keychain Access (search "wm Local Signing").
set -euo pipefail

NAME="wm Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="$(uuidgen)"

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout "pass:$PASS"

security import "$TMP/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P "$PASS" -T /usr/bin/codesign

echo "Created \"$NAME\". Run 'make install', then grant Accessibility one last time."
