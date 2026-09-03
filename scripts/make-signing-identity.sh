#!/bin/bash
# Create a self-signed code-signing identity in the login keychain (one time).
#
# Why: macOS ties Full Disk Access and other permission grants to a binary's code
# signature. An ad-hoc signature changes with every build, so grants are lost on each
# reinstall. Signing with a stable certificate keeps them across rebuilds.
#
# This asks for your password once to trust the certificate for code signing.
set -euo pipefail
NAME="${1:-remtasks Code Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/openssl.cnf" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CFG

# Use the system OpenSSL/LibreSSL: its PKCS#12 defaults are what 'security import' expects.
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/openssl.cnf" 2>/dev/null
PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout "pass:$PASS" -name "$NAME"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
echo "Imported \"$NAME\" into the login keychain. Trusting it for code signing (macOS will ask for your password)..."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "\"$NAME\"" || { echo "Identity not found after import"; exit 1; }
echo "Done. scripts/install.sh will now sign with this identity."
