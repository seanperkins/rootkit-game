#!/usr/bin/env bash
# One-time setup for the `macos` job in .github/workflows/release.yml, in the
# same shape as sound-mural-app's match vault: the signed p12 lives in a
# PRIVATE repo (seanperkins/rootkit-macos-certs) encrypted by its own
# password; the runner reads it with a read-only deploy key; only the small
# credentials live in Actions secrets.
#
#   1. Keychain Access -> Login keychain -> "My Certificates" ->
#      select "Developer ID Application: Sean Perkins (HH3SJBAS42)"
#      (the one with a private key; NOT the Frost Solutions item) ->
#      File > Export Items... -> Personal Information Exchange (.p12),
#      set any new password.
#   2. ./tools/configure_macos_ci.sh /path/to/exported.p12
#
# The Apple ID / app-specific password / team ID are read from THIS
# machine's login keychain (the notarytool-profile item release_mac.sh
# already uses), so no credential is written into the repo.
set -euo pipefail

P12="${1:?usage: configure_macos_ci.sh <exported-signing.p12>}"
REPO="${REPO:-seanperkins/rootkit-game}"
VAULT="seanperkins/rootkit-macos-certs"

[ -f "$P12" ] || { echo "no such file: $P12" >&2; exit 1; }
read -r -s -p "p12 password (the one you set in Keychain Access): " P12PW
echo
[ -n "$P12PW" ] || { echo "empty password" >&2; exit 1; }

# --- publish the encrypted p12 into the vault repo -------------------------
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh repo clone "$VAULT" "$TMP/vault" -- --depth=1
cp "$P12" "$TMP/vault/macos-signing.p12"
( cd "$TMP/vault" \
  && git config user.name "Sean Perkins" \
  && git config user.email "sean@mobility-labs.com" \
  && git add macos-signing.p12 \
  && git commit -q -m "macos-signing.p12: $(date -u +%Y-%m-%d)" \
  && git push -q origin main )
echo "pushed $VAULT/macos-signing.p12"

# --- a read-only deploy key, CI's way into the vault ------------------------
ssh-keygen -t ed25519 -f "$TMP/macos_certs_ed25519" -N "" -C "rootkit-release-ci"
if gh repo deploy-key list -R "$VAULT" --json id --jq '.[0].id' >/dev/null 2>&1; then
  echo "deploy key already present on $VAULT (leaving it)"
else
  gh repo deploy-key add "$TMP/macos_certs_ed25519.pub" \
    -R "$VAULT" -t "GitHub Actions (read-only)"
  echo "added read-only deploy key to $VAULT"
fi

# --- the notarization credentials, from this machine's notarytool profile ----
BLOB=$(security find-generic-password \
  -a "com.apple.gke.notary.tool.saved-creds.notarytool-profile" -w \
  "$HOME/Library/Keychains/login.keychain-db")
APPLE_ID=$(printf '%s' "$BLOB" | python3 -c \
  "import plistlib,binascii,sys;print(plistlib.loads(binascii.unhexlify(sys.stdin.buffer.read().strip()))['appleId'])")
APP_PW=$(printf '%s' "$BLOB" | python3 -c \
  "import plistlib,binascii,sys;print(plistlib.loads(binascii.unhexlify(sys.stdin.buffer.read().strip()))['password'])")
TEAM_ID=$(printf '%s' "$BLOB" | python3 -c \
  "import plistlib,binascii,sys;print(plistlib.loads(binascii.unhexlify(sys.stdin.buffer.read().strip()))['teamId'])")

gh secret set MACOS_CERTS_DEPLOY_KEY --repo "$REPO" < "$TMP/macos_certs_ed25519"
gh secret set MACOS_CERT_PASSWORD --repo "$REPO" --body "$P12PW"
gh secret set MACOS_APPLE_ID --repo "$REPO" --body "$APPLE_ID"
gh secret set MACOS_APPLE_ID_PASSWORD --repo "$REPO" --body "$APP_PW"
gh secret set MACOS_TEAM_ID --repo "$REPO" --body "$TEAM_ID"
gh secret set MACOS_IDENTITY --repo "$REPO" \
  --body "Developer ID Application: Sean Perkins (HH3SJBAS42)" || true

echo "secrets set for $REPO:"
echo "  MACOS_CERTS_DEPLOY_KEY  (read-only key into $VAULT)"
echo "  MACOS_CERT_PASSWORD     (the p12 passphrase)"
echo "  MACOS_APPLE_ID / MACOS_APPLE_ID_PASSWORD / MACOS_TEAM_ID"
echo "  MACOS_IDENTITY"
echo "Next: push release.yml, then 'gh workflow run release.yml' rehearses it."
