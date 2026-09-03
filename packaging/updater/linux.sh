#!/usr/bin/env bash
# ROOTKIT update helper (Linux). Ran by the game from the OS cache — the
# bundled copy is about to be deleted by the swap this performs. The game has
# already verified the archive (RSA-4096 signature + SHA-256); this only
# replaces the game directory and optionally relaunches it.
#
#   linux.sh --archive <tar.gz> --target <game-dir> [--relaunch 1|0] [--state <file>]
#
# POSIX-sh safe; tar is on every Linux the game ships for.
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

# The game spawned us and then quits. Wait for it.
for _ in $(seq 1 120); do
  if ! pgrep -f "ROOTKIT.x86_64" >/dev/null 2>&1; then break; fi
  sleep 1
done

STAGE="$TARGET/.ROOTKIT-update-$$"
rm -rf "$STAGE"; mkdir -p "$STAGE"
if ! tar -xzf "$ARCHIVE" -C "$STAGE"; then
  echo "$ME: unpack failed" >&2; rm -rf "$STAGE"; exit 1
fi
if [ ! -f "$STAGE/ROOTKIT.x86_64" ]; then
  echo "$ME: no ROOTKIT.x86_64 in the archive" >&2; rm -rf "$STAGE"; exit 1
fi
chmod +x "$STAGE/ROOTKIT.x86_64" 2>/dev/null || true

# Clean swap with a rollback path, mirroring macos.sh: the old contents move
# aside first, and only a successful move of the new ones destroys them. The
# staging dir is dot-named, so the glob never touches it. The running helper
# is at the OS cache, so moving the old copies of "updater.sh" is safe too.
OLD="$TARGET/.ROOTKIT-old-$$"
mkdir -p "$OLD"
if ! mv "$TARGET"/* "$OLD"/; then
  echo "$ME: could not stage the old contents" >&2; exit 1
fi
if ! mv "$STAGE"/* "$TARGET"/; then
  mv "$OLD"/* "$TARGET"/ 2>/dev/null || true
  echo "$ME: swap failed; rolled back" >&2; exit 1
fi
rm -rf "$OLD"
rm -rf "$STAGE"
[ -n "$STATE" ] && rm -f "$STATE"
rm -f "$ARCHIVE"
if [ "$RELAUNCH" = "1" ]; then
  "$TARGET/ROOTKIT.x86_64" >/dev/null 2>&1 &
fi
