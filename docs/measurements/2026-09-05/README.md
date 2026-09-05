# Measurement artifacts

Raw JSONL observations from the September 5 implementation. See [the implementation record](../../progression-bosses-music.md) for interpretation and limits.

- `baseline.jsonl`: old linear curve, before themed bosses; mixed complete and partial runs from a working-tree snapshot that already included teleporter/subnet work.
- `candidate.jsonl`: onset 6, divisor 4; rejected.
- `gentle.jsonl`: onset 6, divisor 8; rejected.
- `late.jsonl`: selected onset 20, divisor 2, before themed bosses.
- `integrated-campaign.jsonl`: selected curve with all three bosses; fresh four-player corruption policy, full campaign win.
- `boss-balance-final.jsonl`: six isolated low-DPS encounters, with stepped world time rather than the director's capped clock.
- `final-perf.txt` and `*-tests.txt`: runner evidence, including the earlier performance failure and final passing reruns.
- `audio-bank.txt`: cold/cached bank and incremental voice-family timings plus sampled PCM digests.

The `.gd.txt` files preserve temporary instruments without adding them to the permanent suite. For replay, copy `progression_survey.gd.txt` to `tools/progression_survey.gd`; `boss_balance.gd.txt` extends that path. `baseline_driver.gd.txt` belongs to the earlier source snapshot and is historical, not directly compatible with final boss identities. `review_bosses_music.gd.txt` requires a window and writes posed screenshots and a mixer recording; it is not an input-driven campaign.

Example after restoring the final progression instrument:

```sh
godot --headless -s res://tools/progression_survey.gd -- label=integrated seeds=20260830 profiles=fresh parties=4 policies=corruption limit=90000
```

These instruments print diagnostics directly; inspect their output for script errors. Functional acceptance uses `tools/run_tests.sh`, whose error detection is stricter than a raw Godot exit code.
