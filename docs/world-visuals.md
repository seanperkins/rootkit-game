# World visuals: circuitry, terrain equipment, and effect panels

The original worlds share one bright green floor lattice. The strongest
opportunity is to give the empty space a recognizable structure and quiet
activity while keeping enemies, terrain hazards, and the escape route readable.

This pass gives subnet 1 branching green data buses, subnet 2 blue memory banks,
and subnet 3 violet core sockets. Blank sectors and varied branch lengths break
up repetition. A slow current travels over the traces. The lattice is dimmer so
the additional detail stays behind combat in the visual hierarchy.

The art remains procedural. Static floor commands are cached until the visible
arena set changes. Circuitry uses small cached patches that the renderer can
cull. Their point arrays are retained too, so showing a hidden canvas does not
regenerate the circuitry. The shader shades narrow lines and needs no screen
copy, noise texture, particles, or additional fullscreen pass. It consumes no simulation RNG and
sits below the existing opaque collapse mask. Collision and gameplay state
are unchanged.

## Terrain equipment and effect panels

Terrain walls now have three equipment styles: low cooling units with fins,
taller server housings with recessed lid panels and shelf seams, and relay
modules with central sockets. Their footprints are unchanged. Heights, cool
accent colors, and offset status lights give them variety while retaining the
original 0.6 face transparency. The whole object, including its markings and
lights, falls and fades with its supporting ground.

Each wall's projected geometry is cached in a record. The box uses five drawing
commands instead of twelve; adding its engraving and status strips brings it
to seven. There are no new nodes per wall.

Floor effects remain flat. Hazard zones have warning hatching and a triangular
warning mark; slow zones have three drag bars; corruption zones have nested
sockets and a six-segment recharge gauge. Corruption markings dim while the
zone recharges, using the same timer as the existing fill. All markings sit
below the opaque missing-ground mask. Geometry is cached, only visible panels
are drawn, and each costs at most three multiline commands.

## Review and reproduce

Worktree: `/private/tmp/rootkit-world-visuals`, branch `codex/world-visuals`.
Based on `9b86858`; concurrent uncommitted gameplay work in the original
checkout is not included.

```sh
godot --path /private/tmp/rootkit-world-visuals -s res://tools/shot_world_visuals.gd
godot --path /private/tmp/rootkit-world-visuals -s res://tools/shot_collapse.gd
```

The first tool saves all three views under `.tmp/world-subnet-{1,2,3}.png`.
The collapse tool saves `/tmp/collapse_1_frontier.png` and
`/tmp/collapse_2_route.png`. Both use test save paths.

`tools/shot_terrain_details.gd` captures actual generated hazard, slow, charged
corruption, and empty corruption panels under `.tmp/terrain-*.png`.

For an interleaved original/new comparison, place the original
`scripts/run/backdrop.gd` from `9b86858` at `.tmp/backdrop_baseline.gd`, then run:

```sh
godot --path /private/tmp/rootkit-world-visuals -s res://tools/fps_world_visuals.gd -- ab_baseline_fullscreen_memory
```

The benchmark uses the existing four-player combat fixture and alternates the
two backdrops every 40 frames, discarding settling frames. In the inherited
report, “with” means the new floor and “without” means the original. `_memory`
puts the most detailed pattern in the same combat arena so its workload can
be compared directly. Omit `_fullscreen` for the 1280×720 window.

## Circuit-floor validation and performance limits (9f6354f)

`tools/run_tests.sh --fast`: all 61 suites passed with no script errors. The
draw-order suite includes checks for bounded arena roots, camera culling,
geometry reuse, collapse-mask depth, and unchanged multiplayer state hashes.
The final point-array cache was subsequently exercised by the rendered A/B
probe. All three subnet views and the collapse frontier were inspected.

Final interleaved measurement: Apple M2, Metal / Forward+, 2940×1846,
four-player fixture, mean 468 live enemies, densest circuit pattern.

| Renderer | Samples | Median frame | p95 frame |
|---|---:|---:|---:|
| Original | 952 | 16.66 ms | 17.70 ms |
| Updated | 937 | 16.65 ms | 17.93 ms |

The median was effectively unchanged, but p95 was 0.23 ms higher. This run
clustered around the display interval despite disabling vsync; other agents
were also testing on this machine during the investigation. These results
do **not** prove zero performance impact. Keep this as a reviewable prototype
until a quiet, uncapped comparison establishes the slow-frame behavior.
The headless simulation perf gate was not rerun: it cannot measure the GPU
cost being evaluated here.

## Equipment/panel performance comparison

For this comparison the accepted circuit floor remains visible in both halves.
Put `scripts/run/props.gd` from `9f6354f` at `.tmp/props_baseline.gd`, then run:

```sh
godot --path /private/tmp/rootkit-world-visuals -s res://tools/fps_world_visuals.gd -- ab_props_fullscreen
godot --path /private/tmp/rootkit-world-visuals -s res://tools/fps_world_visuals.gd -- ab_props_panels_fullscreen
```

The second configuration keeps three large effect panels in view as a render
stress without modifying simulation terrain, collision, or damage.

Normal four-player combat on the M2 at 2940×1846 (mean 412 live enemies):

| Renderer | Median frame | p95 frame |
|---|---:|---:|
| Previous walls, plain effect fills | 8.51 ms | 12.69 ms |
| Equipment walls and effect markings | 8.39 ms | 12.78 ms |

These timings are close; the 0.12 ms median improvement and 0.09 ms p95 increase
do not establish a meaningful performance change on their own. This comparison
measures only the equipment/panel addition, not the earlier circuit-floor pass.

With three large panels forced into view (mean 458 live enemies), median was
16.65 ms updated versus 16.66 ms previous, and p95 was 17.99 versus 17.73 ms.
That run again clustered around the display interval, so the stress result is
inconclusive for small performance differences; it is not a zero-cost claim.

Equipment/panel verification: `tools/run_tests.sh --fast` passed all 61 suites
with no script errors. Added checks cover geometry reuse, the three wall
heights, state-hash isolation, panel draw depth, recharge at 0/50/100%, and
cache invalidation when terrain is replaced. Actual generated panels were
inspected in all three effect types, including depleted corruption, and the
updated walls were inspected at the collapse frontier.
