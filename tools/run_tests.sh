#!/usr/bin/env bash
# Run every ROOTKIT suite and report honestly.
#
# A suite printing "PASS" is NOT sufficient evidence that it passed. A runtime
# error in GDScript aborts only the function it happened in: the engine prints
# SCRIPT ERROR, _initialize carries on, and a suite whose assertions never ran
# exits 0 saying PASS. That has already hidden two real breakages here — a
# missing Terrain.slide, and test_campaign holding a reference to a deleted
# field for a whole commit.
#
# So the runner reads stderr as well as the verdict. Any SCRIPT ERROR or Parse
# Error fails the suite whatever it claims about itself.
#
# Usage: tools/run_tests.sh [--fast]     (--fast skips the perf gate)
set -uo pipefail
cd "$(dirname "$0")/.."

SUITES=(
  test_terrain test_terrain_run test_gates test_campaign test_collapse
  test_build test_slots test_fusion test_fusion_run test_blocks test_cadence test_drain test_corruption test_dispatch
  test_triggers test_worms test_wards test_multipliers test_travel
  test_behaviour test_effects test_minibosses test_cards_keyboard test_draw_order
  test_player_stats test_player_sheet test_meta test_meta_layout test_run
  test_feel test_synth test_audio_events test_input test_prefs test_hud test_arrivals test_flow test_interpolation
  test_determinism_rules test_meta_derivation test_lockstep test_plurality test_offers
  test_manifest test_snapshot_hostile test_multiplayer_sim test_transport_loopback
  test_lobby test_recovery test_ending test_parking test_reconnect test_facing
)
[ "${1:-}" = "--fast" ] || SUITES+=(perf_milestone0)

failed=0
inconclusive=0
for t in "${SUITES[@]}"; do
  out=$(godot --headless -s "res://tests/$t.gd" 2>&1)
  code=$?
  # INCONCLUSIVE is the perf gate declining to judge a contended machine. It
  # exits 0 with no PASS line, which used to read here as "FAIL exit 0" with
  # a blank verdict — a real-looking failure with nothing to fix.
  verdict=$(printf '%s\n' "$out" | grep -E "^  (PASS|FAIL|INCONCLUSIVE)" | head -1)
  errs=$(printf '%s\n' "$out" | grep -cE "SCRIPT ERROR|Parse Error")
  if [ "$errs" -gt 0 ]; then
    printf '%-20s BROKEN  %d script error(s) — a case aborted; any PASS above is meaningless\n' "$t" "$errs"
    printf '%s\n' "$out" | grep -E "SCRIPT ERROR|Parse Error" | head -3 | sed 's/^/                     /'
    failed=$((failed + 1))
  elif [ "$code" -ne 0 ] || [ -z "$verdict" ]; then
    printf '%-20s FAIL    exit %d  %s\n' "$t" "$code" "$verdict"
    failed=$((failed + 1))
  elif [[ "$verdict" == *INCONCLUSIVE* ]]; then
    printf '%-20s %s\n' "$t" "$verdict"
    inconclusive=$((inconclusive + 1))
  else
    printf '%-20s %s\n' "$t" "$verdict"
  fi
done

echo
if [ "$failed" -eq 0 ] && [ "$inconclusive" -eq 0 ]; then
  echo "  ALL GREEN — ${#SUITES[@]} suites, no script errors"
elif [ "$failed" -eq 0 ]; then
  echo "  GREEN BUT UNJUDGED — $inconclusive suite(s) inconclusive (machine too contended); rerun on a quiet machine"
else
  echo "  $failed of ${#SUITES[@]} suites failed"
fi
exit $((failed > 0))
