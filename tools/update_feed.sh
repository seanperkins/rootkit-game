#!/usr/bin/env bash
# Build the signed update feed for a release.
#
#   tools/update_feed.sh <tag>            # fresh feed from build/ assets
#   tools/update_feed.sh <tag> --merge    # replace this tag's entries, keep
#                                         # other platforms entries (a local
#                                         # run usually lacks the Linux/Windows
#                                         # assets — merge keeps them)
#   tools/update_feed.sh genkey           # make the signing keypair, print the
#                                         # public key (paste into
#                                         # scripts/update/update_feed.gd)
#
# The private key NEVER ships. Local: ~/.config/rootkit/update_sign.key (or
# UPDATE_SIGN_KEY_FILE). CI: Actions secret UPDATE_SIGN_KEY holds the base64
# PEM, decoded in the feed job. Public: embedded in update_feed.gd.
set -euo pipefail

TAG="${1:-}"
MODE="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
KEY="${UPDATE_SIGN_KEY_FILE:-$HOME/.config/rootkit/update_sign.key}"
REPO="seanperkins/rootkit-game"

genkey() {
  local dir="$HOME/.config/rootkit"
  mkdir -p "$dir" && chmod 700 "$dir"
  if [ -f "$dir/update_sign.key" ]; then
    echo "key already exists at $dir/update_sign.key — not overwriting" >&2
  else
    openssl genrsa -out "$dir/update_sign.key" 4096 2>/dev/null
    chmod 600 "$dir/update_sign.key"
    echo "private key: $dir/update_sign.key (chmod 600)"
    echo "CI secret UPDATE_SIGN_KEY = base64 -A of that file:"
    openssl base64 -A -in "$dir/update_sign.key"
  fi
  echo "public key (paste into scripts/update/update_feed.gd PUBKEY):"
  openssl rsa -in "$dir/update_sign.key" -pubout 2>/dev/null
  exit 0
}

[ "$TAG" = "genkey" ] && genkey
[ -n "$TAG" ] || { echo "usage: tools/update_feed.sh <tag> [--merge] | genkey" >&2; exit 1; }
[ -f "$KEY" ] || { echo "missing signing key — run tools/update_feed.sh genkey" >&2; exit 1; }

VERSION="${TAG#v}"
OUT="$BUILD/latest.json"

python3 - "$TAG" "$VERSION" "$BUILD" "$REPO" "$KEY" "$MODE" "$OUT" <<'PY'
import base64, hashlib, json, os, subprocess, sys
tag, version, build, repo, key, mode, out = sys.argv[1:]

ASSETS = {
    "macos": f"ROOTKIT-{tag}-macos.zip",
    "windows": f"ROOTKIT-{tag}-windows.zip",
    "linux": f"ROOTKIT-{tag}-linux.tar.gz",
}

existing = {}
if mode == "--merge" and os.path.exists(out):
    with open(out) as f:
        old = json.load(f)
    existing = old.get("entries", {})

entries = {}
for platform, asset in ASSETS.items():
    path = os.path.join(build, asset)
    if not os.path.exists(path):
        continue  # a local run may not have every platform's archive
    sha = subprocess.run(["openssl", "dgst", "-sha256", path],
                         capture_output=True, text=True, check=True).stdout.split()[-1]
    sig = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key, "-binary"],
        stdin=open(path, "rb"), capture_output=True, check=True).stdout
    sig_b64 = base64.b64encode(sig).decode()
    entries[platform] = {
        "version": version,
        # The URL is PER-TAG, not /latest/: a merged feed keeps another
        # platform's older entry, and /latest/download/ would 404 it the
        # moment the newer release claims the "latest" redirect.
        "url": f"https://github.com/{repo}/releases/download/{tag}/{asset}",
        "sha256": sha,
        "sig": sig_b64,
    }

# Merge keeps platforms this run did not build, so a local macOS-only release
# does not silently remove the Windows/Linux entries from the live feed.
for platform, entry in existing.items():
    if platform not in entries:
        entries[platform] = entry

manifest = {"version": version, "entries": entries}
with open(out, "w") as f:
    json.dump(manifest, f, indent=1)
print(f"wrote {out}: {sorted(entries.keys())}")
PY

echo "next: gh release upload '$TAG' '$OUT' --clobber  (and self-check: tools/verify_feed.gd)"
exit 0
