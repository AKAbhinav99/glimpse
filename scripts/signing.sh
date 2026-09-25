#!/bin/bash
# Creates (once) a private self-signed code-signing certificate so every build of Glimpse has the same
# identity. macOS then keeps Camera/Accessibility permission and Keychain access across updates.
# It lives in its own keychain file (not your login keychain) and is only used to sign Glimpse.
set -euo pipefail
DIR="$HOME/Library/Application Support/Glimpse-Signing"
KC="$DIR/signing.keychain-db"
PASSFILE="$DIR/keychain-password"
NAME="Glimpse Local Signing"

if [ ! -f "$KC" ]; then
  mkdir -p "$DIR"; chmod 700 "$DIR"
  openssl rand -hex 24 > "$PASSFILE"; chmod 600 "$PASSFILE"
  PASS=$(cat "$PASSFILE")
  TMP=$(mktemp -d)
  cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:glimpse 2>/dev/null
  # create-keychain adds itself to the search list; remember the list and restore it afterwards.
  ORIG=$(security list-keychains -d user | tr -d '"' | xargs)
  security create-keychain -p "$PASS" "$KC"
  security list-keychains -d user -s $ORIG
  security set-keychain-settings "$KC"
  security unlock-keychain -p "$PASS" "$KC"
  security import "$TMP/id.p12" -k "$KC" -P glimpse -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KC" >/dev/null
  rm -rf "$TMP"
fi

security unlock-keychain -p "$(cat "$PASSFILE")" "$KC"
# Print the certificate's SHA-1 so the build can sign with it.
security find-certificate -c "$NAME" -Z "$KC" | awk '/SHA-1/{print $3}'
