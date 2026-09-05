# Entity design pass

Branch `codex/entity-designs`, based on `main` at `8d77d40`.

The player is a small interceptor with twin engine pods, a raised armored hull,
a white command core, and exhaust that lengthens with movement. Its nose and
weapons share the existing facing vector. Teammate colors, damage tint, parked
opacity, and name tags still come from the existing player presentation state.

Enemies use procedural silhouettes with dark armor, beveled neon edges, and
small exposed cores. Each role has distinct hardware: firewall vent slots,
worm scutes, sentinel lances, tracer wings, watchdog optics, rootkit cloaking
petals, and paired probe barrels. Mini-bosses have larger bodies; fork-bomb
children become smaller as they split. The packet filter's front armor follows
the velocity used by its damage rule. Charge visuals follow committed aim.
ICE has a hexagonal fortress shell. Corruption and hit-flash colors still apply
to the complete design, and submerged/arriving entities retain their visibility
rules. Captured botnet processors and data crystals have separate identities.

Weapons have pointed packet capsules, four-footed armed mines, and rotating
orbiter cutters. Arcs carry a bright inner filament; beams have readable outer
rails; cones use an outlined fan with a quieter fill. Hostile shots have a red
diamond core and a short flight trail. These changes affect presentation only:
collision radii, damage, ranges, timing, RNG, and network state are unchanged.
The existing four MultiMesh pools remain; there are no image assets or
per-enemy nodes.

## Review

From the worktree:

```sh
godot -s res://tools/shot_entity_designs.gd
godot -s res://tools/fps_entity_designs.gd -- rows5
```

The first tool writes `.tmp/entity-designs.png` (labeled lineup at game scale)
and `.tmp/entity-combat.png` (a staged crowd, including corrupted enemies).
The second runs the existing four-player performance fixture with five weapon
rows and saves `.tmp/entity-live.png` from active combat. Both use test saves
and require a window; a headless renderer cannot capture the shader output.

## Validation

`tools/run_tests.sh test_draw_order test_facing test_interpolation test_arrivals
test_manifest test_determinism_rules perf_milestone0` passed all seven suites
with no script errors. The simulation gate reported p95 9.179 ms against its
load-scaled 9.866 ms budget. This headless figure does not measure shader cost.
The lineup and staged crowd were also rendered with Metal / Forward+ on Apple
M2 and visually inspected.

The windowed five-row probe completed 2,400 frames at 1280×720, averaging
484 live enemies. Median frame time was 16.66 ms and p95 was 18.11 ms; render
submission averaged 0.48–0.55 ms across population bands. Frames clustered
around the display interval despite the probe requesting disabled vsync, and
Metal reported no GPU timing. This verifies live rendering under load but is
not an uncapped comparison with the previous designs or proof of zero overhead.
The live capture was inspected for player visibility, hostile fire, orbiters,
articulated worms, pickups, and wall occlusion.
