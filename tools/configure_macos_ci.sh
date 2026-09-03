#!/usr/bin/env bash
# One-time setup for the `macos` job in .github/workflows/release.yml, in the
# same shape as sound-mural-app's match vault: the signing p12 lives in a
# PRIVATE repo (seanperkins/rootkit-macos-certs) encrypted by its own
# passphrase; the runner reads it with a read-only deploy key; notarization
# uses the App Store Connect API key (4XBH56T7RS) already on this machine.
#
#   1. Keychain Access -> Login keychain -> "My Certificates" ->
#      select "Developer ID Application: Sean Perkins (HH3SJBAS42)"
#      (the one with a private key; NOT the Frost Solutions item) ->
#      File > Export Items... -> Personal Information Exchange (.p12),
#      set any new password.
#   2. ./tools/configure_macos_ci.sh /path/to/exported.p12
#
# The p12 is RE-WRAPPED under a freshly generated 48-hex passphrase before
# it is pushed, and verified to be the Developer ID identity WITH a private
# key before a single byte reaches the vault. The ASC key id and issuer are
# not secrets (they name nothing without the .p8, sound-mural's Fastfile
# says the same); the key content is.
set -euo pipefail

P12="${1:?usage: configure_macos_ci.sh <exported-signing.p12>}"
REPO="${REPO:-seanperkins/rootkit-game}"
VAULT="seanperkins/rootkit-macos-certs"
ASC_KEY_ID="4XBH56T7RS"
P8="$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8"

[ -f "$P12" ] || { echo "no such file: $P12" >&2; exit 1; }
[ -f "$P8" ] || { echo "no asc key at $P8 (expected id $ASC_KEY_ID)" >&2; exit 1; }
read -r -s -p "original p12 password (the one you set in Keychain Access): " P12PW
echo
[ -n "$P12PW" ] || { echo "empty password" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- re-wrap under a generated passphrase ------------------------------------
VLT_PW=$(openssl rand -hex 24)
# Keychain Access exports a legacy RC2/3DES p12; OpenSSL 3.x refuses it
# without -legacy (sound-mural's docs hit this exact trap). Try modern
# first, then retry with -legacy on the INPUT side only. Both stages use
# FILES: OpenSSL 3.6's pkcs12 -export cannot read a PEM stream from
# stdin ("Could not find certificates from -in file from <stdin>"), so a
# pipe shape fails on a perfectly good p12.
if ! openssl pkcs12 -in "$P12" -passin "pass:$P12PW" -nodes \
  -out "$TMP/raw.pem" 2>"$TMP/rw.err"; then
  if ! openssl pkcs12 -legacy -in "$P12" -passin "pass:$P12PW" -nodes \
    -out "$TMP/raw.pem" 2>"$TMP/rw.err"; then
    echo "could not read the p12 — openssl said:" >&2
    cat "$TMP/rw.err" >&2
    exit 1
  fi
  echo "re-wrapped with -legacy (Keychain Access legacy p12)"
fi
# sound-mural's measured table: macOS security import accepts only
# -legacy -macalg sha1 on a real PKCS#12; openssl-3 defaults and bare
# -legacy both fail with "MAC verification failed" even WITH a password.
if ! openssl pkcs12 -legacy -macalg sha1 -export -in "$TMP/raw.pem" \
  -passout "pass:$VLT_PW" -out "$TMP/macos-signing.p12" 2>"$TMP/rw2.err"; then
  echo "could not re-export the p12 — openssl said:" >&2
  cat "$TMP/rw2.err" >&2
  exit 1
fi

# --- verify WHAT was exported before anything is pushed ----------------------
# Catches the Frost Solutions item or a certificate-only export locally,
# instead of a green script that burns a CI run on a mismatched identity.
if ! openssl pkcs12 -in "$TMP/macos-signing.p12" -passin "pass:$VLT_PW" -nodes \
  -out "$TMP/verify.pem" 2>"$TMP/verify.err"; then
  echo "could not verify the re-wrapped p12 — openssl said:" >&2
  cat "$TMP/verify.err" >&2
  exit 1
fi
SUBJ=$(openssl crl2pkcs7 -nocrl -certfile "$TMP/verify.pem" \
  | openssl pkcs7 -print_certs -noout)
case "$SUBJ" in
  *"Developer ID Application"*) ;;
  *) echo "WRONG IDENTITY: $SUBJ" >&2
     echo "expected 'Developer ID Application' — did you export the Frost Solutions item?" >&2
     exit 1 ;;
esac
if ! grep -qE "BEGIN (RSA )?PRIVATE KEY" "$TMP/verify.pem"; then
  echo "no private key in the p12 — exported a certificate without its key?" >&2
  exit 1
fi
echo "verified: Developer ID Application identity with private key"

# --- push to the vault -------------------------------------------------------
gh repo clone "$VAULT" "$TMP/vault" -- --depth=1
cp "$TMP/macos-signing.p12" "$TMP/vault/macos-signing.p12"
( cd "$TMP/vault" \
  && git config user.name "Sean Perkins" \
  && git config user.email "sean@mobility-labs.com" \
  && git add macos-signing.p12 \
  && git commit -q -m "macos-signing.p12: $(date -u +%Y-%m-%d)" \
  && git push -q origin main )
echo "pushed re-wrapped p12 to $VAULT/macos-signing.p12"

# --- a read-only deploy key, CI's way into the vault -------------------------
ssh-keygen -t ed25519 -f "$TMP/macos_certs_ed25519" -N "" -C "rootkit-release-ci"
COUNT=$(gh repo deploy-key list -R "$VAULT" --json id --jq 'length' 2>/dev/null || echo 0)
COUNT="${COUNT:-0}"
if [ "$COUNT" -gt 0 ] 2>/dev/null; then
  echo "deploy key(s) already present on $VAULT (leaving them)"
else
  gh repo deploy-key add "$TMP/macos_certs_ed25519.pub" \
    -R "$VAULT" -t "GitHub Actions (read-only)"
  echo "added read-only deploy key to $VAULT"
fi

# --- the secrets -------------------------------------------------------------
gh secret set MACOS_CERTS_DEPLOY_KEY --repo "$REPO" < "$TMP/macos_certs_ed25519"
gh secret set MACOS_CERT_PASSWORD --repo "$REPO" --body "$VLT_PW"
base64 < "$P8" | gh secret set ASC_KEY_CONTENT --repo "$REPO"
gh secret set MACOS_IDENTITY --repo "$REPO" \
  --body "Developer ID Application: Sean Perkins (HH3SJBAS42)" || true

echo "secrets set for $REPO:"
echo "  MACOS_CERTS_DEPLOY_KEY  (read-only key into $VAULT)"
echo "  MACOS_CERT_PASSWORD     (the generated vault passphrase)"
echo "  ASC_KEY_CONTENT         (base64 of AuthKey_${ASC_KEY_ID}.p8)"
echo "  MACOS_IDENTITY"
echo "Next: push release.yml, then 'gh workflow run release.yml' rehearses it."
