#!/usr/bin/env bash
# Create a stable self-signed code-signing certificate for the fork so the
# Accessibility (TCC) grant survives rebuilds.
#
# Why: ad-hoc signing (`codesign -s -`) gives the bundle a designated
# requirement pinned to the binary's CDHash, which changes on every build, so
# macOS invalidates the Accessibility grant each rebuild. A self-signed cert
# gives a stable, identity-based designated requirement, so you grant
# Accessibility once and it persists. See FORK_CHANGES.md → "Accessibility
# permission".
#
# Idempotent: a no-op once the identity exists.
set -euo pipefail

IDENTITY="Ghostty Fork Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Match with the non-`-v` listing: a self-signed cert reports
# CSSMERR_TP_NOT_TRUSTED, so `-v` (valid-only) never lists it and the guard
# would keep minting duplicates that make `codesign -s` ambiguous. Untrusted is
# fine — trust gates verification/Gatekeeper, not signing. Mirrors 03-build.sh.
if security find-identity -p codesigning | grep -qF "$IDENTITY"; then
  echo "Code-signing identity '$IDENTITY' already exists — nothing to do."
  security find-identity -p codesigning | grep -F "$IDENTITY"
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Generating self-signed code-signing certificate '$IDENTITY'…"
openssl req -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" \
  -x509 -days 3650 -out "$tmp/cert.pem" \
  -subj "/CN=$IDENTITY/O=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

# -legacy: OpenSSL 3.x defaults to a PKCS#12 MAC/cipher Apple's `security`
# importer rejects ("MAC verification failed"); -legacy emits the SHA1/3DES
# format it understands. A throwaway passphrase is more reliable than empty.
P12PASS="ghostty-fork-local"
openssl pkcs12 -export -legacy -out "$tmp/cert.p12" \
  -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$IDENTITY" -passout "pass:$P12PASS"

echo "Importing into login keychain…"
# -A: let any tool use the key without a per-app prompt (local dev cert).
# -T /usr/bin/codesign: explicitly authorize codesign.
security import "$tmp/cert.p12" -k "$KEYCHAIN" -P "$P12PASS" -A -T /usr/bin/codesign

echo
echo "Done. Code-signing identities now available:"
security find-identity -p codesigning | grep -F "$IDENTITY" || true
