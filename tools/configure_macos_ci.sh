#!/usr/bin/env bash
# One-time setup for the `macos` job in .github/workflows/release.yml:
# uploads the signing cert and the notarization credentials as repository
# secrets, so the hosted runner can sign and notarise without the local
# keychain. Run on the machine that owns the Developer ID identity.
#
#   1. Keychain Access -> Login keychain -> "My Certificates" ->
#      select "Developer ID Application: Sean Perkins (HH3SJBAS42)"
#      (the one with a private key) -> File > Export Items...
#      -> Personal Information Exchange (.p12), choose any new password.
#   2. ./tools/configure_macos_ci.sh /path/to/exported.p12
#
# The Apple ID / app-specific password / team ID are read from THIS
# machine's login keychain (the notarytool-profile item release_mac.sh
# already uses), so no credential is written into the repo.
set -euo pipefail

P12="${1:?usage: configure_macos_ci.sh <exported-signing.p12>}"
REPO="${REPO:-seanperkins/rootkit-game}"

[ -f "$P12" ] || { echo "no such file: $P12" >&2; exit 1; }
read -r -s -p "p12 password (the one you set in Keychain Access): " P12PW
echo
[ -n "$P12PW" ] || { echo "empty password" >&2; exit 1; }

# Notarytool profile already in the login keychain (Apple ID authentication,
# no API key needed: app-specific passwords work headless).
BLOB=$(security find-generic-password \
  -a "com.apple.gke.notary.tool.saved-creds.notarytool-profile" -w \
  "$HOME/Library/Keychains/login.keychain-db")
APPLE_ID=$(printf '%s' "$BLOB" | python3 -c \
  "import plistlib,binascii,sys;print(plistlib.loads(binascii.unhexlify(sys.stdin.buffer.read().strip()))['appleId'])")
APP_PW=$(printf '%s' "$BLOB" | python3 -c \
  "import plistlib,binascii,sys;print(plistlib.loads(binascii.unhexlify(sys.stdin.buffer.read().strip()))['password'])")
TEAM_ID=$(printf '%s' "$BLOB" | python3 -c \
  "import plistlib,binascii,sys;print(plistlib.loads(binascii.unhexlify(sys.stdin.buffer.read().strip()))['teamId'])")

base64 < "$P12" | gh secret set MACOS_CERT_P12 --repo "$REPO"
gh secret set MACOS_CERT_PASSWORD --repo "$REPO" --body "$P12PW"
gh secret set MACOS_APPLE_ID --repo "$REPO" --body "$APPLE_ID"
gh secret set MACOS_APPLE_ID_PASSWORD --repo "$REPO" --body "$APP_PW"
gh secret set MACOS_TEAM_ID --repo "$REPO" --body "$TEAM_ID"

# Optional: override the codesign identity on the runner (subtle but there,
# in case the cert is re-issued under a different CN).
gh secret set MACOS_IDENTITY --repo "$REPO" \
  --body "Developer ID Application: Sean Perkins (HH3SJBAS42)" || true

echo "secrets set for $REPO: MACOS_CERT_P12, MACOS_CERT_PASSWORD,"
echo "  MACOS_APPLE_ID, MACOS_APPLE_ID_PASSWORD, MACOS_TEAM_ID, MACOS_IDENTITY"
echo "Next: push the workflow, then 'gh workflow run release.yml' rehearses it."
