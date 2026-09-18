#!/bin/bash
# Creates the self-signed code signing certificate TabMaximize is signed with.
#
# Why this exists: TCC anchors an Accessibility grant to the bundle id *and* a code
# requirement captured when the grant was made. An ad-hoc signature (codesign -s -)
# has no certificate, so that requirement collapses to the exact build's cdhash —
# and every rebuild invalidates it. The symptom is maddening: the app still shows in
# System Settings with its switch ON while AXIsProcessTrusted() returns false.
#
# With a real leaf certificate the requirement becomes
#     identifier "com.bamf.tabmaximize" and certificate leaf H"..."
# which survives rebuilds indefinitely, as long as the certificate and bundle id
# stay the same.
set -euo pipefail

NAME="${1:-TabMaximizeSelfSigned}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Certificate '$NAME' already exists in the login keychain — nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
# The p12 password never leaves this script; it exists only because macOS refuses to
# import an empty-password PKCS#12.
PW="tabmaximize-import"

echo "Generating a self-signed code signing certificate: $NAME"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -days 3650 \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# OpenSSL 3 defaults to AES/SHA-256 for the PKCS#12 MAC, which macOS cannot read —
# hence the explicit legacy algorithms.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/identity.p12" -passout "pass:$PW" -name "$NAME" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

echo "Importing into the login keychain..."
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PW" \
    -T /usr/bin/codesign -T /usr/bin/security -A

# Importing alone is not enough. Since macOS Sierra, a key also needs its partition
# list set before a tool may use it unattended; without this, every single build stops
# on a "codesign wants to use a key in your keychain" dialog. Neither -T nor -A avoids
# it. Setting the partition list requires the login keychain password, which is why
# this script is interactive and is not run as part of a normal build.
echo ""
echo "macOS needs your login keychain password so codesign can use the new key"
echo "without stopping to ask on every build. (Nothing is stored or transmitted.)"
if security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1; then
    : # empty password worked (unusual, but harmless to try first)
else
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$KEYCHAIN" >/dev/null || {
        echo ""
        echo "Could not set the partition list. The certificate is still usable, but the"
        echo "first codesign of each build will show a keychain dialog — click"
        echo "'Always Allow' once and it will stop asking."
    }
fi

# Deliberately no `security add-trusted-cert`: codesign signs happily with an
# untrusted self-signed leaf, and adding trust would pop a second authorization dialog
# for no benefit. `security find-identity -v -p codesigning` will not list this
# identity for the same reason — that is expected and does not matter.
echo ""
echo "Verifying the identity can actually sign..."
MARKER="$TMP/marker"
: > "$MARKER"
if codesign --force --sign "$NAME" --timestamp=none "$MARKER" 2>/dev/null; then
    echo "Done. Now run: make install"
else
    echo "The certificate was imported but codesign could not use it."
    echo "Open Keychain Access, find the '$NAME' private key, and set Access Control to"
    echo "'Allow all applications to access this item'."
    exit 1
fi
