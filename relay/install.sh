#!/usr/bin/env bash
# Install or refresh the ROOTKIT relay on Ubuntu 24.04. Run as root from the
# project copy relay/deploy.sh put on the droplet: the relay script needs
# project.godot, scripts/ and data/ for its class names.
set -euo pipefail
GODOT_VERSION="4.7"
DEST=/opt/rootkit-relay
SRC="$(cd "$(dirname "$0")/.." && pwd)"

apt-get update -qq >/dev/null && apt-get install -y -qq unzip curl ufw rsync >/dev/null
id -u rootkit >/dev/null 2>&1 || useradd --system --home "$DEST" --shell /usr/sbin/nologin rootkit
mkdir -p "$DEST"
if [ ! -x "$DEST/godot" ]; then
  curl -sSL -o /tmp/godot.zip \
    "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
  rm -rf /tmp/godot && unzip -qo /tmp/godot.zip -d /tmp/godot
  mv "/tmp/godot/Godot_v${GODOT_VERSION}-stable_linux.x86_64" "$DEST/godot"
  chmod +x "$DEST/godot"
fi
# The project files the relay needs for class resolution, and the relay
# itself. No scenes, tests, builds or docs.
mkdir -p "$DEST/project"
# Excludes are ROOT-ANCHORED: a bare "build" also matched scripts/build/, and
# the relay shipped without the Module class it depends on through
# SaveGame -> ModuleTable. Scenes stay: the import wants the main scene.
rsync -a --delete --exclude /.godot --exclude /build --exclude /tests --exclude /site \
  --exclude /docs --exclude /.github --exclude /tools --exclude '*.png' \
  "$SRC/" "$DEST/project/"
chown -R rootkit:rootkit "$DEST"
# Godot's import wants more than the smallest droplet's 458 MB: give it swap.
if ! swapon --show | grep -q swapfile; then
  fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null && swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
# Import once so the global class cache exists for the headless run; the
# relay script cannot resolve SessionRules or RelayServer without it. The
# cache deploy.sh shipped from the developer machine is the fallback.
CACHE="$DEST/project/.godot/global_script_class_cache.cfg"
if [ -f "$SRC/.godot/global_script_class_cache.cfg" ]; then
  # The developer machine's cache is complete; the droplet's own import was
  # measured producing a partial one (no Module) even with swap.
  mkdir -p "$DEST/project/.godot"
  cp "$SRC/.godot/global_script_class_cache.cfg" "$CACHE"
  chown -R rootkit:rootkit "$DEST/project/.godot"
else
  sudo -u rootkit "$DEST/godot" --headless --path "$DEST/project" --import >/dev/null 2>&1 || true
fi
[ -f "$CACHE" ] || { echo "no global class cache; the relay will not start" >&2; exit 1; }
install -m 644 "$SRC/relay/rootkit-relay.service" /etc/systemd/system/rootkit-relay.service
systemctl daemon-reload
systemctl enable rootkit-relay >/dev/null
systemctl restart rootkit-relay
ufw allow 43211/udp >/dev/null
ufw allow OpenSSH >/dev/null
ufw --force enable >/dev/null
sleep 2
systemctl --no-pager --lines=5 status rootkit-relay
