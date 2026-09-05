# Teleporter, shared vote and next-subnet modifiers

Date: 2026-09-04. Original approved design, superseded in part on 2026-09-05.

**Implemented direction, September 5:** the user selected both larger arenas and
hidden side rooms, and removed the need to pre-generate a connected campaign.
The current implementation loads one subnet at a time, uses an in-arena transfer
pad with no bridge, generates the destination after its vote, and reconstructs
it from seed/subnet/route during recovery. Main arenas are about 31% larger;
network jobs reveal optional archive rooms. The frozen voter roster below is
implemented. The fixed-footprint template/bridge requirements below are historical
and superseded by this explicit user decision. See the maintained
[implementation record](../../teleporter-subnets.md) for shipped behavior,
route magnitudes, animation and verification.

Companions: [Spawners](2026-09-04-spawner-points-design.md), [Bosses](2026-09-04-themed-bosses-design.md), [Leveling](2026-09-04-leveling-pace-design.md).

## Player contract

Boss death opens the escape route and starts the existing collapse, not the vote. The party walks the existing corridor to a visibly distinct teleporter pad. All LIVE players gather; the shared three-card vote opens; its winning modifier configures the next subnet; the party teleports to that arena's separated arrival points. The final subnet still ends on boss death without a vote.

Keep `COLLAPSE_SECONDS` and `CORRIDOR_COLLAPSE_TICKS` and their simulation-time progression. Voting uses the same world pause as existing card offers; it does not add a wall-clock collapse timer. An open UI holds the world, not input/roster processing. The old invariant of never teleporting is intentionally superseded for this directed transition only.

## Grounded integration points

Current `run.gd:_step2c_gate` advances once all LIVE centers pass `g.end`. Current `_advance_subnet` clears the field, heals/banks, resets the director and advances terrain without relocating players. Those are the transition sites, not permission to regenerate an arena after players have walked into it.

Current `_apply_choice` handles FUSION, then otherwise decodes module cards. LEVEL_VOTE requires a distinct branch before that decoder; `_apply_first` and slot-exit handling also need explicit examination for the new kind. A vote index must never be interpreted as a module code.

RNG state already belongs in `STATE_FIELDS`: `rng_sim.state`, `rng_block.state`, `rng_card%d.state` at `run.gd:5333–5336`, resolved by `_manifest_object`. Add `rng_vote.state` the same way; seed alone is insufficient after draws.

## Gathering geometry and occupancy

The pad must lie wholly on the corridor side of the next arena boundary. Recommend its center at least `GATE_RADIUS + PLAYER_RADIUS` back from `g.end`, with a gather radius of the existing 48 units; validate against actual cell/boundary geometry rather than assuming `g.end` is outside every next-arena cell. Four non-colliding player footprints must fit on the pad.

Keep a transition barrier at the target boundary until the vote commits. Merely testing “not past g.end” does not stop a player walking into the unopened arena while waiting for teammates. Rendering shows the blocked boundary and pad clearly; no invisible unexplained wall.

A vote only opens with at least one LIVE slot and every LIVE footprint in the safe gather region. Parked slots, enemies, projectiles and temporary zones may not occupy the region to be replaced; define/reset transition entities through existing clear/return paths before applying terrain. No already occupied arena is mutated. On commit, update all LIVE current/previous/render positions and clear stale movement/interpolation without erasing their builds or replaying clear rewards.

## Voting contract

Append `OfferKind.LEVEL_VOTE`. Roll three distinct eligible card IDs from a dedicated seeded stream, snapshot candidates and eligible voter slots at open, and stage choices through existing `card/target/offer` INPUT fields. Each eligible slot may commit one ballot for that offer sequence. Invalid/stale/duplicate choices do nothing; peers apply ballots in the normal ordered input-consumption path.

Recommend the existing first-option timeout policy: a LIVE nonrespondent reaching its deadline votes candidate 0; an eligible slot that parks/exits resolves its pending ballot the same way. Preserve an already committed ballot. A slot absent at open does not gain a ballot by returning. Document that this is a frozen voter roster rather than continually recounting who is LIVE. Solo remains deadline-free under its existing descriptor and resolves on its one pick.

After every eligible ballot resolves, choose the plurality winner. Ties draw only among tied highest totals; no random draw is needed for a unique winner. Close the vote once and apply exactly one result. Last-LIVE death/session termination cancels advancement rather than allowing slot-exit callbacks to advance a lost run. Do not settle recursively midway through offer cleanup or re-open a vote at the same pad.

Queued level/fusion offers remain intact and cannot be mistaken for ballots. Existing pause/waiting behavior must reflect both kinds. A returning/spectating peer can see candidates, progress and the result without receiving another ballot.

## All seven approved modifier categories

Recommendations for review, not measured/approved tuning:

| Category | Example next-subnet change | Example paired reward |
|---|---|---|
| Enemy integrity | ×1.20 integrity | +20% next-boss salvage |
| Spawn rate | ×1.15 ordinary spawn rate | +20% next-boss salvage |
| Hazard density | A preplanned HOT layout with more hazard/slow/corruption zones | +20% next-boss salvage |
| Behavior bias | Shift part of the ordinary wave mix toward a named behavior | +20% next-boss salvage |
| Early/extra miniboss | Advance one existing arrival or add one bounded extra encounter | +20% next-boss salvage |
| Salvage/shards | +50% collected XP/shard rewards, explicitly named | ×1.15 ordinary spawn rate as cost |
| Arena size/density | Select a smaller, denser COMPACT interior | +20% next-boss salvage |

The card must state whether its reward is XP, ordinary salvage or boss salvage; these are not interchangeable. Recommend pairing difficulty with a reward, but do not represent the earlier category selection as approval of those bundles. Keep every category; dropping terrain variants is not an authorized shortcut.

Modifiers affect only the selected next subnet. Resolve them once into active state, separate from immutable base tables and immutable party multipliers. Snapshot/hash active values or validated IDs from which they are deterministically reconstructed. Reset previous effects at the transition, then apply the newly selected effect *after any director reset that would otherwise erase it*. No old reward bonus applies to the just-cleared boss or clear heal accidentally.

For behavior bias, remap only ordinary enemies within a validated pool, preserving total count unless the card explicitly changes rate; exclude boss/miniboss identities. Earlier/extra encounters cannot double-fire, overlap the terminal boss unannounced, or be scheduled in the past. Source baseline arrival times are 80/145/200/240 seconds. Fractional shard rewards use a deterministic carried remainder, not repeated rounding that gives +50% of one XP either zero or double; each shard is consumed once, and the party's shared XP is not multiplied again per player.

## Preplanned terrain variants

Keep one globally planned campaign grid and its arena allocations. Prepare NORMAL, HOT and COMPACT templates for each vote-eligible arena before play. NORMAL preserves baseline; HOT increases safe-to-place zone coverage; COMPACT reserves a smaller playable interior inside the fixed outer footprint, with elevated obstacle density. Arena dimensions never expand into another arena/corridor. All templates preserve entry/exit routes, spawner pads and the boss's required navigable region.

Every selectable variant must deliver its advertised effect. A failed COMPACT roll must not silently become a copy of NORMAL. Use a deterministic known-valid compact construction as fallback during generation, or refuse the layout before play. Similarly, a HOT card cannot win and then place zero additional effective hazards because a runtime retry budget ran out.

Templates include collision cells, zone mappings, wall/zone rectangles used for rendering, connectivity and spawn metadata. Select/apply only the unopened target arena; rebuild the relevant collision/gate/distance/flow/presentation caches as required. Copying only `solid` while leaving `rects`/zone indices unchanged would produce invisible walls and stale hazards.

Static templates are derived from seed+build and classified accordingly. **Active variant IDs are simulation state**: hash/snapshot them. Restore validates selections, reconstructs active geometry from templates before dynamic terrain overlays/collapse state, then rebuilds derived caches. This is mandatory even if the raw templates themselves need no snapshot bytes. HOT zones persist for the declared subnet including its boss fight, not merely a 300-second timer that expires when the boss arrives.

## Snapshot and boundary validation

Validate the entire candidate/tally/ballot/active-effect/variant/RNG structure before any write: correct types and lengths, finite bounded numbers, recognized card/variant IDs, distinct candidates, legal target subnet, one ballot per eligible slot, totals matching ballots, and consistent open/resolved state. Validate incoming offer contents for LEVEL_VOTE separately from module/fusion payloads. Recover the same pending vote and the same post-vote layout on every peer. Update snapshot/protocol/build compatibility gates where the changed contract requires it; unchanged INPUT byte width does not mean unchanged semantics.

## Presentation and acceptance

1. The escape route ends at an actual visible teleporter with party-gather status; players cannot enter the unselected arena. After selection they arrive visibly separated with no interpolation streak.
2. Three cards show concrete next-subnet changes, units and rewards; keyboard/controller/mouse selection stage the same vote. Waiting/timeout/spectator feedback is clear, and closing an overlay cannot secretly cast or duplicate a vote.
3. Majority, two-way/three-way ties, stale input, timeout, parking, reconnect and last-LIVE loss produce the declared one-time outcome on all peers. Snapshot before/after a tie consumes the same RNG sequence.
4. Each modifier changes observable combat/reward/terrain behavior, expires correctly and cannot change the subnet's boss identity. Independent traversal checks verify each variant and full player footprints at arrivals.
5. The repository runner passes after integration and a windowed co-op run exercises both transitions through final victory. Measure the extra generation/snapshot/performance cost; do not merely assert that tables and state fields exist.
