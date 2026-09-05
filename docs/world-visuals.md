# World visuals: circuitry and ambient current

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
regenerate the circuitry. The shader shades narrow lines and needs no screen copy, noise texture,
particles, or additional fullscreen pass. It consumes no simulation RNG and
sits below the existing opaque collapse mask. Walls, collision, hazards, and
gameplay state are unchanged.

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

## Validation and performance limits

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

## Further art direction

The next useful step would be distinctive machinery silhouettes built into
existing walls and ambient indicators that respond to the gate or corruption
zone state. Those changes should preserve the current translucent occlusion
rules and be measured separately. More bloom or a fullscreen animated floor
would affect many more pixels; the existing frame probe identifies pixel cost
as a concern at native Retina resolution.
