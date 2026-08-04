#!/bin/bash
# One-time: create a stable self-signed identity so freeflow keeps the same
# fingerprint across rebuilds → you grant Accessibility ONCE, forever.
# Run this yourself (it needs your Mac login password for one step).
set -euo pipefail

IDENTITY="freeflow-dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ identity '$IDENTITY' already exists — nothing to do."
    exit 0
fi

echo "▸ generating self-signed code-signing certificate…"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$TMP/ff.key" -out "$TMP/ff.crt" -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
openssl pkcs12 -export -legacy -macalg sha1 -out "$TMP/ff.p12" \
    -inkey "$TMP/ff.key" -in "$TMP/ff.crt" -passout pass:ff -name "$IDENTITY" >/dev/null 2>&1

echo "▸ importing into your login keychain…"
security import "$TMP/ff.p12" -k "$KEYCHAIN" -P ff -T /usr/bin/codesign -A

echo "▸ authorizing codesign to use the key (this is the password step)…"
read -r -s -p "   Enter your Mac login password: " PW; echo
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KEYCHAIN" >/dev/null

echo
echo "✓ done. Now rebuild — it'll sign with '$IDENTITY' automatically:"
echo "    ./build_app.sh && open freeflow.app"
echo "  Grant Accessibility one last time, and it'll stick from now on."
