#!/usr/bin/env bash
# Create (or reuse) the relay droplet and install the relay on it.
#   relay/deploy.sh [--key-id N]
# Needs doctl (authenticated) and ssh. Prints the droplet's IP: paste it into
# SessionRules.RELAY_ADDRESS and cut a release. Idempotent: an existing
# rootkit-relay droplet is reused and only the files and service refresh.
set -euo pipefail
NAME=rootkit-relay
REGION=nyc3
SIZE=s-1vcpu-512mb-10gb
IMAGE=ubuntu-24-04-x64
KEY_ID="${KEY_ID:-}"
while [ $# -gt 0 ]; do
  case "$1" in
    --key-id) KEY_ID="$2"; shift 2 ;;
    *) echo "unknown argument $1" >&2; exit 1 ;;
  esac
done
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [ -z "$KEY_ID" ]; then
  # The first DigitalOcean key whose fingerprint matches a local public key.
  for pub in "$HOME"/.ssh/*.pub; do
    [ -f "$pub" ] || continue
    fp=$(ssh-keygen -E md5 -lf "$pub" | awk '{print $2}' | sed 's/^MD5://')
    KEY_ID=$(doctl compute ssh-key list --format ID,FingerPrint --no-header | awk -v f="$fp" '$2==f {print $1}' | head -1)
    [ -n "$KEY_ID" ] && break
  done
fi
[ -n "$KEY_ID" ] || { echo "no DigitalOcean SSH key matches a local ~/.ssh/*.pub; pass --key-id" >&2; exit 1; }

IP=$(doctl compute droplet list --format Name,PublicIPv4 --no-header | awk -v n="$NAME" '$1==n {print $2}')
if [ -z "$IP" ]; then
  echo "creating $NAME in $REGION ($SIZE)…"
  doctl compute droplet create "$NAME" --region "$REGION" --size "$SIZE" --image "$IMAGE" \
    --ssh-keys "$KEY_ID" --tag-name rootkit --wait >/dev/null
  IP=$(doctl compute droplet list --format Name,PublicIPv4 --no-header | awk -v n="$NAME" '$1==n {print $2}')
fi
echo "droplet $NAME at $IP"
for _ in $(seq 1 30); do
  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@"$IP" true 2>/dev/null && break
  sleep 5
done
ssh root@"$IP" 'command -v rsync >/dev/null || (apt-get update -qq >/dev/null && apt-get install -y -qq rsync >/dev/null); mkdir -p /root/rootkit-src'
rsync -a --delete --exclude .godot --exclude build --exclude site --exclude .git "$ROOT/" root@"$IP":/root/rootkit-src/
ssh root@"$IP" 'bash /root/rootkit-src/relay/install.sh'
echo
echo "relay is up at $IP:43211"
echo "next: set SessionRules.RELAY_ADDRESS := \"$IP\" and cut a release"
