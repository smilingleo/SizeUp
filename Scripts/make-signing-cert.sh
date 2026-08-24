#!/usr/bin/env bash
# Create a stable code-signing identity, so macOS stops asking for
# Accessibility and Screen Recording access on every rebuild.
#
# Why this exists
# ---------------
# TCC (the privacy database) remembers a permission grant against the app's
# *designated requirement*, not its path. An ad-hoc signature (`codesign -s -`)
# has no certificate, so the only thing it can name the app by is the hash of
# its own code:
#
#     designated => cdhash H"2b4ef50d..."
#
# Every rebuild changes a byte somewhere, the cdhash changes with it, and macOS
# concludes it has never seen this app before. The grant is still in the
# database -- it just no longer matches anything.
#
# Signing with a certificate, even a self-signed one nobody trusts, changes the
# requirement to something that does not move:
#
#     designated => identifier "com.lliu.sizeup2" and certificate leaf = H"13b5..."
#
# Both halves are stable across rebuilds, so the grant keeps matching and is
# given exactly once. The certificate never has to be trusted by Gatekeeper for
# this to work; it only has to exist and stay the same.
#
# This is safe to re-run: it does nothing if the identity is already there.
set -euo pipefail

NAME="${SIGNING_IDENTITY:-ClipShot Dev}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

if security find-certificate -c "${NAME}" "${KEYCHAIN}" >/dev/null 2>&1; then
    echo "Signing identity '${NAME}' already exists — nothing to do."
    echo
    security find-certificate -c "${NAME}" -Z "${KEYCHAIN}" | grep "SHA-256 hash" || true
    exit 0
fi

echo "Creating a self-signed code-signing certificate '${NAME}'…"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# `extendedKeyUsage=codeSigning` is what makes codesign willing to use it.
openssl req -newkey rsa:2048 -nodes \
    -keyout "${WORK}/key.pem" \
    -x509 -days 7300 \
    -out "${WORK}/cert.pem" \
    -subj "/CN=${NAME}" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    2>/dev/null

# The Security framework cannot read OpenSSL 3's default PKCS#12 encryption, so
# ask for the old algorithms explicitly. Without this the import fails with
# "MAC verification failed".
openssl pkcs12 -export \
    -out "${WORK}/cert.p12" \
    -inkey "${WORK}/key.pem" \
    -in "${WORK}/cert.pem" \
    -passout pass:clipshot \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    2>/dev/null

# -T /usr/bin/codesign pre-authorises codesign to use the key, so signing does
# not pop a keychain prompt every single build.
security import "${WORK}/cert.p12" \
    -k "${KEYCHAIN}" \
    -P clipshot \
    -T /usr/bin/codesign \
    -A

# On modern macOS the ACL above is not enough on its own: the key's partition
# list also has to name codesign, or the first signature still raises a GUI
# prompt. This needs the login keychain password, so it is best-effort -- if it
# is skipped, macOS asks once and "Always Allow" has the same effect.
if security set-key-partition-list \
        -S apple-tool:,apple:,codesign: \
        -s -k "" "${KEYCHAIN}" >/dev/null 2>&1; then
    echo "Pre-authorised codesign to use the key."
else
    cat <<'EOF'

Note: could not set the key partition list without your keychain password.
The first build will show a prompt asking whether codesign may use this key.
Choose "Always Allow" and it will not ask again.
EOF
fi

echo
echo "Created '${NAME}'. Rebuild with 'make build' and grant Accessibility once."
echo "That grant will now survive every later rebuild."
