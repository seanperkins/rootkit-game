# Per-arena spawner points

Date: 2026-09-04. Status: approved feature; formation dimensions are recommended implementation defaults. Documentation only.

Overview: [Ideas review](2026-09-04-ideas-proposals-design.md). Companion: [Teleporter vote](2026-09-04-teleporter-vote-design.md).

## Contract

Every arena reserves four open, reachable, non-hazardous, separated arrival points at generation time, indexed by player slot. Initial spawn and teleporter arrival use those points. Nonoverlap is the requested feature: a failed search must never fall back to the same point for several slots.

The current `_derive_roster` does not assign `player_pos`; allocation leaves every slot at the origin. Current `_advance_subnet` preserves continuous walking. The teleporter feature intentionally supersedes that transition behavior, consuming this feature's next-arena points. Do not preserve the old no-teleport invariant at the expense of the approved teleporter.

## Placement recommendation

Source: `scripts/run/terrain.gd:_place_gates`, `_place_walls`, `_place_zones`, `_fill_unreachable`; `scripts/run/run.gd:_derive_roster`, `_return`.

Wall and zone placement reject rectangles whose `grow(WALL_MARGIN)` contains the entry. Reuse that reserved region rather than add another random retry algorithm. Verify the full player footprint, arena boundary, gate blockers and connectivity as well as the point's cell: the clearance rule for generated obstacles alone is not proof about boundary rock or a new compact-variant frame.

For arenas after the first, FRONT is the incoming gate's inward direction and SIDE its perpendicular. For arena 0 use RIGHT/DOWN. Recommend these offsets from entry:

| Slot | FRONT offset | SIDE offset |
|---|---:|---:|
| 0 | 80 | 90 |
| 1 | 80 | -90 |
| 2 | 180 | 90 |
| 3 | 180 | -90 |

Maximum point distance is about 201.25 units, inside the current 260-unit `WALL_MARGIN`; minimum pair separation is 100 units. Recommend a minimum separation contract of 96 units, also checked against player diameter. Dimensions are tuneable, not extra approved balance numbers.

Generation explicitly reserves/clears the entry pad and its connection into the playable arena before final connectivity checks. Normal, extra-zone and compact interiors must all preserve it. After all wall, frame, zone and boss-anchor steps, validate every point's player-sized clearance, safe zone status, same-arena membership and reachability to the arena's playable region. If a supposedly valid generated layout violates this, refuse to start that session with a clear generation error. `assert` is only a development backstop: it is stripped in exported builds and cannot be the release failure path. There is no silent overlap fallback and no regeneration beneath players during a run.

## Data and consumers

Proposed API: `Terrain.spawner_pos(arena_index, slot) -> Vector2`, backed by four reserved positions per arena/variant. Return validated coordinates; invalid indices are programmer errors, not permission to return `(0,0)`.

- `_derive_roster`: place every roster slot at its own arena-0 point; prime previous/render positions so the first frame does not interpolate from the origin.
- `_advance_subnet`, owned by the teleporter plan: after selecting the next layout and advancing `terrain.current`, place each LIVE slot at its own point. Clear movement/interpolation state that would carry the old location into the new frame; preserve facing/build/health according to the transition contract.
- `_return`: preserve returning near a LIVE party rather than teleporting a returnee across the arena. Choose a safe, distinct point near the party using bounded candidate search that excludes current LIVE footprints; deterministic slot-order handling covers simultaneous returns. When no LIVE anchor exists, use the returning slot's reserved point if still safe (not voided). Reuse existing parking/ending policy if the world has no safe return region; never revive into a collapsed cell or silently stack returnees.

The requested first/next-arena nonoverlap is unconditional. The reconnect extension must not be advertised as solved by changing only the no-LIVE center fallback: a second return in the same tick sees the first as LIVE.

## Terrain and boss integration

The companion vote spec owns selection/reconstruction of NORMAL, HOT and COMPACT interiors inside the fixed campaign grid. These layout variants keep the same entry-pad formation where possible; no compact rock frame or additional hazard covers it.

Sentinel Array has separate, distant capture anchors in arena 0, prepared by the boss generation step. Both entry pads and capture anchors must survive the final connectivity/zone validation pass. The boss owns its formation; neither system assumes the other's clearance extends across the whole arena.

## Determinism and snapshots

Generation templates are reconstructed from the descriptor seed and build. Their raw template arrays are derived state, classified in `NOT_IN_MANIFEST` where required. Active variant IDs and any runtime layout selection are simulation state owned by the vote feature and must be hashed/snapshotted. Do not describe the active layout as generation-only after a vote changes it.

Player positions, previous simulation state and roster changes continue through the existing manifest. Presentation interpolation is re-primed after teleport/restore. No device, node reference or wall-clock input enters terrain generation or simulation.

## Acceptance

1. Across a fixed diverse seed set and every supported interior variant, all four points are distinct, safe for the full player radius, reachable and within the intended entry region.
2. Initial four-player spawn and both teleporter arrivals visibly separate players without interpolation across the jump. Solo occupies slot 0's point; sparse rosters retain stable slot indexing.
3. An intentionally obstructed entry-pad fixture is either repaired during generation by the declared reservation step or rejected explicitly in an exported build; it never yields coincident or embedded spawn points.
4. Simultaneous reconnects do not choose the same LIVE anchor point; collapsed/unsafe reserved points are never used blindly. Identical recorded return order gives identical placement across peers.
5. A snapshot after selecting COMPACT reconstructs the same active terrain and spawner interpretation; position hashes agree. Run the repository runner and actual windowed multiplayer spawn/arrival smoke during implementation, not while drafting these docs.
