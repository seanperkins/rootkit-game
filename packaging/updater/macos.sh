#!/usr/bin/env bash
# ROOTKIT update helper (macOS). Ran by the game from the OS cache — the
# bundled copy is about to be deleted by the swap this performs. The game has
# already verified the archive (RSA-4096 signature + SHA-256); this only
# replaces the bundle atomically and optionally relaunches it.
#
#   macos.sh --archive <zip> --target <parent-of-ROOTKIT.app>
#            [--relaunch 1|0] [--state <state-file>]
#
# The archives are built with `ditto -c -k --sequesterRsrc --keepParent`, so
# ditto -x -k is the ONLY safe unpacker — it restores the bundle's mode bits
# and AppleDouble metadata that a generic unzip would drop. Never swap
# contents: the signing/staple verification covers the whole bundle.
set -u

ARCHIVE="" TARGET="" RELAUNCH=0 STATE="" ME="$(basename "$0")"
while [ $# -gt 0 ]; do
  case "$1" in
    --archive) ARCHIVE="$2"; shift 2 ;;
    --target) TARGET="$2"; shift 2 ;;
    --relaunch) RELAUNCH="$2"; shift 2 ;;
    --state) STATE="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$ARCHIVE" ] && [ -n "$TARGET" ] || { echo "$ME: --archive and --target are required" >&2; exit 1; }

# The game spawned us and then quits. Wait for it so the bundle lock is gone.
for _ in $(seq 1 120); do
  if ! pgrep -x ROOTKIT >/dev/null 2>&1; then break; fi
  sleep 1
done

STAGE="$TARGET/.ROOTKIT-update-$$"
rm -rf "$STAGE"; mkdir -p "$STAGE"
if ! ditto -x -k "$ARCHIVE" "$STAGE"; then
  echo "$ME: unpack failed" >&2; rm -rf "$STAGE"; exit 1
fi
if [ ! -d "$STAGE/ROOTKIT.app" ]; then
  echo "$ME: no ROOTKIT.app in the archive" >&2; rm -rf "$STAGE"; exit 1
fi

OLD="$TARGET/ROOTKIT.old-$$"
if [ -d "$TARGET/ROOTKIT.app" ]; then
  mv "$TARGET/ROOTKIT.app" "$OLD"
fi
if ! mv "$STAGE/ROOTKIT.app" "$TARGET/ROOTKIT.app"; then
  mv "$OLD" "$TARGET/ROOTKIT.app" 2>/dev/null || true
  rm -rf "$STAGE"
  echo "$ME: swap failed; rolled back" >&2
  exit 1
fi
rm -rf "$OLD" "$STAGE"
[ -n "$STATE" ] && rm -f "$STATE"
rm -f "$ARCHIVE"
if [ "$RELAUNCH" = "1" ]; then
  open "$TARGET/ROOTKIT.app"
fi
