#!/usr/bin/env bash
# Build, sign, notarise and publish the macOS release for a tag.
#
#   tools/release_mac.sh v0.1.0
#
# Windows and Linux come from .github/workflows/release.yml on the same tag;
# both sides create the GitHub Release if it is missing and upload with
# --clobber, so the order does not matter and either can run again.
#
# Needs: godot 4.7 with its export templates, Xcode command line tools, gh
# logged in, the "Developer ID Application" identity in the login keychain,
# and a notarytool keychain profile (xcrun notarytool store-credentials).
set -euo pipefail

TAG="${1:?usage: tools/release_mac.sh vX.Y.Z}"
IDENTITY="${IDENTITY:-Developer ID Application: Sean Perkins (HH3SJBAS42)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-profile}"
# Named explicitly: the default keychain on this machine flips to a
# fastlane temp keychain that other projects recreate, and a profile stored
# there vanishes with it.
NOTARY_KEYCHAIN="${NOTARY_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/macos/ROOTKIT.app"
ZIP="$ROOT/build/ROOTKIT-$TAG-macos.zip"
VERSION="${TAG#v}"

cd "$ROOT"
for tool in godot xcrun codesign ditto gh; do
  command -v "$tool" >/dev/null || { echo "missing: $tool" >&2; exit 1; }
done
[ -z "$(git status --porcelain --untracked-files=no)" ] || {
  echo "working tree is not clean; commit or stash first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || {
  echo "tag $TAG does not exist; git tag $TAG && git push origin $TAG" >&2; exit 1; }

# The version the build carries comes from the tag, never from a hand edit.
sed -i '' "s|^config/version=.*|config/version=\"$VERSION\"|" project.godot
grep -q "^config/version=" project.godot || sed -i '' "s|^config/name=\"ROOTKIT\"|config/name=\"ROOTKIT\"\nconfig/version=\"$VERSION\"|" project.godot
trap 'git checkout -q project.godot' EXIT

rm -rf "$APP" "$ZIP"
mkdir -p "$ROOT/build/macos"
godot --headless --import >/dev/null 2>&1 || true
godot --headless --export-release macos "$APP"
[ -d "$APP" ] || { echo "export produced no app" >&2; exit 1; }

# The updater helper rides INSIDE the bundle and BEFORE codesign (and
# therefore before notarization): the signature and staple cover whatever the
# package ships — a helper copied in afterwards would break both. It is what
# this build will use to swap in the NEXT version.
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/packaging/updater/macos.sh" "$APP/Contents/Resources/updater.sh"
chmod +x "$APP/Contents/Resources/updater.sh"

# Godot exported with an ad-hoc signature; replace it with the Developer ID,
# hardened runtime and the entitlements a Godot binary needs.
codesign --force --deep --options runtime --timestamp \
  --entitlements "$ROOT/tools/macos.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"

# Notarise a zip of the app, then staple the ticket to the app itself.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ROOT/build/notary.zip"
xcrun notarytool submit "$ROOT/build/notary.zip" --keychain-profile "$NOTARY_PROFILE" \
  --keychain "$NOTARY_KEYCHAIN" --wait
rm -f "$ROOT/build/notary.zip"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute -v "$APP"

# The zip users download: the stapled app, resource forks preserved.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

gh release view "$TAG" >/dev/null 2>&1 \
  || gh release create "$TAG" --title "ROOTKIT $TAG" --generate-notes
gh release upload "$TAG" "$ZIP" --clobber
echo "uploaded $(basename "$ZIP") to release $TAG"

# The update feed. Signing needs the private key: tools/update_feed.sh genkey
# makes it at ~/.config/rootkit/update_sign.key. Merge keeps the Windows and
# Linux CI entries when this local run only built macOS.
"$ROOT/tools/update_feed.sh" "$TAG" --merge
gh release upload "$TAG" "$ROOT/build/latest.json" --clobber
echo "uploaded build/latest.json to release $TAG"
