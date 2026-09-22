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

# Signing works with an untrusted certificate, but TCC does NOT: it will not
# honour a certificate-based designated requirement unless the certificate is
# trusted, and silently falls back to the cdhash - which changes every build.
# This step needs your password, so it is left for you to run.
security find-certificate -c "$SIGN_ID" -p > "$TMP/cert.pem"

cat <<MSG

Created '$SIGN_ID'.

ONE MORE STEP - run this yourself and approve the password prompt:

    security find-certificate -c "$SIGN_ID" -p > /tmp/macnizer-cert.pem
    security add-trusted-cert -r trustRoot -p codeSign /tmp/macnizer-cert.pem
    rm /tmp/macnizer-cert.pem

Without it the certificate stays untrusted, macOS ignores the stable signature,
and Accessibility access is revoked on every rebuild.

Then: ./build.sh, grant Accessibility once, and it will persist.
MSG
