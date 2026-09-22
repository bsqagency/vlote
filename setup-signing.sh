#!/bin/bash
# Creates a stable self-signed code-signing identity, so that Accessibility and
# Automation grants survive rebuilds. Run once. Safe to re-run.
set -euo pipefail

SIGN_ID="Macnizer Local Signing"

if security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "Identity '$SIGN_ID' already exists — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS="macnizer-transfer"   # protects the temp transfer file only; deleted below

openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -subj "/CN=$SIGN_ID" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# LibreSSL (the system openssl) cannot use -legacy; real OpenSSL 3 needs it for
# a PKCS12 MAC that macOS `security` can verify.
if openssl version | grep -qi libressl; then
    openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" \
        -in "$TMP/cert.pem" -passout "pass:$PASS" -name "$SIGN_ID"
else
    openssl pkcs12 -legacy -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" \
        -in "$TMP/cert.pem" -passout "pass:$PASS" -name "$SIGN_ID"
fi

# -T /usr/bin/codesign pre-authorises codesign to use the key, so signing never
# stops to ask. The certificate is never marked trusted: codesign does not need
# that, and not touching trust settings means no authorisation prompt.
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db \
    -P "$PASS" -T /usr/bin/codesign

cat <<MSG

Created '$SIGN_ID'.

Next: ./build.sh, then grant Accessibility once.

If macOS keeps asking for Accessibility even though the switch is already ON,
the entry is stale - left over from an earlier ad-hoc signed build, which TCC
identified by a hash that changes on every rebuild. Clear it and grant again:

    tccutil reset Accessibility com.brandsquare.macnizer

Verified: with this identity the grant survives rebuilds, because the
designated requirement becomes `identifier + certificate leaf` rather than a
cdhash. Check with:

    codesign -d -r- build/Macnizer.app
MSG
