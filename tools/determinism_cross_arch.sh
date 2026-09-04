#!/usr/bin/env bash
# Reproduce CI's cross-architecture determinism check locally, in Docker.
#
# CI runs tools/determinism_probe.gd on ubuntu-latest (x86_64) and
# ubuntu-24.04-arm (arm64) and byte-diffs the output. That loop is ~7 minutes
# per push and cannot be stepped into. This is the same comparison on one
# machine, so a fix can be iterated on before it is pushed.
#
#   tools/determinism_cross_arch.sh            # 1800 ticks, the CI default
#   tools/determinism_cross_arch.sh 6000       # longer, to reach later subnets
#
# Exit status IS the result: 0 identical, 1 diverged, 2 could not run. That is
# deliberate — it makes the script usable in a bisect or a loop, which is how
# the original divergence was traced to a single manifest field.
#
# NOTE ON COVERAGE. The probe pins `director.elapsed = 999.0` and
# `boss_spawned = true` on subnet 1, so `powi(HP_PER_SUBNET, n>0)`,
# `terrain.nearest_open`, `_advance_subnet`, minibosses and worms may never
# execute. A green run here proves the paths it traverses and nothing about the
# rest. The structural guard in test_determinism_rules
# (`no_libm_reaches_hashed_state`) is what covers those, and it is the
# load-bearing artefact — glibc ifunc-selects `__sin_fma` by CPU feature, so
# even two x86_64 machines can disagree, and this pair only witnesses the
# subset where these two libms happen to differ.

set -euo pipefail

# Pinned to the version .github/workflows/ci.yml installs. "latest" would
# compare two builds that are not the ones CI runs.
readonly GODOT_VERSION="4.7"
readonly IMAGE="ubuntu:24.04"
readonly TICKS="${1:-1800}"

cd "$(dirname "$0")/.."
readonly REPO="$PWD"
CACHE="${TMPDIR:-/tmp}/rootkit-godot-linux"
mkdir -p "$CACHE"

if ! command -v docker >/dev/null 2>&1; then
	echo "docker not found — this script needs linux/amd64 and linux/arm64 images." >&2
	exit 2
fi
if ! docker info >/dev/null 2>&1; then
	echo "docker is installed but not running." >&2
	exit 2
fi

leg() {
	local platform="$1" arch="$2" out="$3"
	# Fail fast rather than hang: an unavailable emulator otherwise spends
	# thirty minutes producing nothing.
	if ! docker run --rm --platform "$platform" "$IMAGE" true >/dev/null 2>&1; then
		echo "cannot run $platform — enable emulation (Rosetta or QEMU) in Docker." >&2
		exit 2
	fi
	# -i: the container script arrives on stdin via `bash -s`, and without it
	# docker attaches nothing, bash reads EOF, and the leg silently produces an
	# empty file that looks like a crash.
	docker run --rm -i --platform "$platform" \
		-v "$REPO:/work" -v "$CACHE:/cache" \
		-e "ARCH=$arch" -e "VER=$GODOT_VERSION" -e "TICKS=$TICKS" \
		"$IMAGE" bash -s > "$out" <<'CONTAINER'
set -euo pipefail
BIN="/cache/Godot_v${VER}-stable_linux.${ARCH}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl unzip ca-certificates libx11-6 libxcursor1 \
	libxinerama1 libxrandr2 libxi6 libgl1 libfontconfig1 libasound2t64 \
	libpulse0 >/dev/null 2>&1
if [ ! -x "$BIN" ]; then
	curl -sSL -o /tmp/g.zip \
		"https://github.com/godotengine/godot/releases/download/${VER}-stable/Godot_v${VER}-stable_linux.${ARCH}.zip"
	unzip -q -o /tmp/g.zip -d /cache
	chmod +x "$BIN"
fi
# Recorded so a green local run is comparable to CI. glibc ifunc-selects
# s_sinf-fma on CPUID: an emulated leg without FMA exercises a DIFFERENT libm
# path than the GitHub runner, so "identical here" would not mean "identical
# there".
{
	echo "# arch    ${ARCH}"
	echo "# fma     $(grep -o -w fma /proc/cpuinfo | head -1 || echo none)"
	echo "# glibc   $(ldd --version | head -1)"
} >&2
cd /work
"$BIN" --headless --import >/dev/null 2>&1 || true
"$BIN" --headless -s res://tools/determinism_probe.gd -- --ticks "$TICKS" 2>/dev/null \
	| grep -E '^(# determinism probe|[0-9]+ -?[0-9]+$)'
CONTAINER
}

ARM_OUT="$(mktemp)"; X86_OUT="$(mktemp)"
trap 'rm -f "$ARM_OUT" "$X86_OUT"' EXIT

echo "== linux/arm64 =="
leg linux/arm64 arm64 "$ARM_OUT"
echo "== linux/amd64 =="
leg linux/amd64 x86_64 "$X86_OUT"

# An empty leg means a crashed Godot, not a divergence. Without this check the
# probe being piped through grep turns a crash into a confusing 1800-line diff.
for f in "$ARM_OUT" "$X86_OUT"; do
	if [ ! -s "$f" ]; then
		echo "a leg produced no output — Godot crashed or the filter matched nothing." >&2
		exit 2
	fi
done

if diff -q "$ARM_OUT" "$X86_OUT" >/dev/null; then
	echo "IDENTICAL — $(wc -l < "$ARM_OUT" | tr -d ' ') lines over $TICKS ticks"
	exit 0
fi
echo "DIVERGED"
diff "$ARM_OUT" "$X86_OUT" | head -20
echo "..."
echo "diverging ticks: $(diff "$ARM_OUT" "$X86_OUT" | grep -c '^<' || true)"
exit 1
