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
# it is pushed, so the hand-typed Keychain Access password never guards the
# key bytes at rest in the vault. The ASC key id and issuer are not
# secrets (they name nothing without the .p8, sound-mural's Fastfile says
# the same); the key content is.
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

# --- re-wrap under a generated passphrase, then push to the vault -----------
VLT_PW=$(openssl rand -hex 24)
if ! openssl pkcs12 -in "$P12" -passin "pass:$P12PW" -nodes 2>/dev/null \
  | openssl pkcs12 -export -passout "pass:$VLT_PW" \
      -out "$TMP/macos-signing.p12" 2>/dev/null; then
  echo "could not re-wrap the p12 (wrong original password?)" >&2
  exit 1
fi

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
