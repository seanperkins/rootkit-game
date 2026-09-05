# Visual polish and HUD instruments

Continues `codex/entity-designs` after the integrated boss-armor health pass.

## Combat and world

Enemy hardware has fixed screen-space lighting and a compact contact shadow
inside its existing quad. No additional enemy nodes, textures, or MultiMesh
pools are added. Equipment surfaces are brighter, edges quieter, and cached
cast-shadow geometry grounds standing walls. Face transparency, collision, and
collapse behavior remain intact; shadows disappear when their equipment falls.

Sparks follow the incoming hit direction. Destruction sends small armor chips
outward, and player weapon mounts kick back briefly with a muzzle flash. The
presentation-only Feel object caps impacts at 24 bursts and recoil at one unit
per player. Both decay through the existing presentation step during pauses
and hitstop. None of this changes damage or uses simulation randomness.

Charger windups fill a sequence of forward chevrons. Surfacing ambushers have
converging brackets, ranged enemies charge a small targeting optic, and kernel
panic fills eight outward reactor strokes before its existing pulse. The last
indicator stays local to its body because that attack uses line of sight, not
a finite circular damage zone. Attack schedules are unchanged.

The floor has a subdued subnet tint. Decorative traces dim smoothly as the
swarm grows, while hazards, gates, and escape indicators keep their contrast.
The edge subnet carries flowing packets, memory banks have traveling scan
bands, and core sockets pulse slowly together. Animation shades cached trace
geometry; it adds no screen copy or animated fullscreen atmosphere pass.

## HUD

Dark, sharply framed panels provide a consistent background for the readouts.
Integrity and time have larger type; health uses a segmented gauge and XP has
a separate blue progress line with its actual value. Shield, armor, defense,
level, resources, and teammate state remain visible. During collapse the large
clock becomes the escape countdown instead of continuing to show combat time.

Five fixed-width weapon slots replace the unbounded multiline build dump.
Each shows the vector and rank, its attached modules, and rearm/inert state
with damage and cooldown. Long lines ellipsize; hovering shows the complete
original build description, also retained in the end summary. The slots scale
with viewport width and leave the center of the arena open.

Recovery notices wrap within their panel, whose height grows to fit. Network
diagnostics begin below it. FPS and version are quiet footer readouts. The
old damage ColorRect had an unused gradient, so it covered the entire screen
with red. Its replacement shades the edges only and sits behind the HUD.
The existing red floor tint during subnet collapse is a separate world cue.

## Reproduce

Run windowed from the worktree; all captures use test saves:

```sh
godot -s res://tools/shot_hud_designs.gd
godot -s res://tools/shot_world_visuals.gd
godot -s res://tools/fps_entity_designs.gd -- rows5
```

Outputs are `.tmp/hud-{combat,critical,collapse,reconnect}.png`,
`.tmp/world-subnet-{1,2,3}.png`, and `.tmp/entity-live.png`.

## Validation and performance

The following focused suites passed without script errors: `test_hud`,
`test_feel`, `test_facing`, `test_draw_order`, `test_manifest`,
`test_determinism_rules`, `test_cards_keyboard`, `test_player_sheet`,
`test_settings_overlay`, `test_arrivals`, and `test_effects`.
HUD checks include all five slots inside 1280×720 and 1920×1080 viewports,
recovery-panel sizing, the collapse countdown, and damage tint below the HUD.
Feel checks exercise impact-cap enforcement and aging, including repeated fire.

`perf_milestone0` passed: real-run p95 9.559 ms against its load-scaled
9.996 ms simulation budget. A separate windowed probe completed 2,400 frames
with four players and five weapon rows, averaging 470.9 live enemies. On
Apple M2 / Metal / Forward+ at 1280×720, median frame time was 16.70 ms and
p95 was 19.00 ms; render submission averaged 0.55–0.65 ms across population
bands. Metal exposed no GPU timing. The frame results still cluster near the
display interval and are not an uncapped A/B measurement or evidence of zero
rendering overhead.

Live combat and all three subnet captures were inspected, along with separate
healthy, critical-health, collapse, and reconnect HUD views. Shader compilation
and the live probe produced no script or shader errors.
