extends Node2D

## The run. Owns the 9-step tick from the spec and every population in it.

## Five times the area of the original 3200x2000, so each side grows by sqrt(5),
## then rounded to a whole EVEN number of Terrain.TILE either way. Even, because
## the first arena is centred on the world origin and a half-size that landed
## mid-tile would put every arena edge part way through a lattice cell — which
## is exactly the seam the backdrop used to draw.
##
## 74 x 46 tiles. ARENA_ORIGIN is derived, never written twice.
const ARENA_SIZE := Vector2(7104, 4416)
const ARENA_ORIGIN := -ARENA_SIZE * 0.5
const CELL := 32.0

## The grid window's side, in world units. Must comfortably exceed the largest
## distance from the player at which anything is queried: steering is gated at
## 820, and a packet travels 640 before expiring (x1.4 with a maxed reach).
const GRID_WINDOW := 3200.0

const MAX_ENEMIES := 600
const MAX_PROJECTILES := 400
const MAX_SHARDS := 1500
const MAX_BOTNET := 64

const ENEMY_RADIUS := 12.0
const PROJECTILE_RADIUS := 4.0
const SEPARATION_RADIUS := 26.0
## Separation only matters where the player can see it. The viewport covers
## roughly 640 px from the player at this zoom, so enemies beyond this keep
## their steering force from the last time they were in range and cost nothing.
## This is the single largest item in the tick and most of it was invisible.
const STEER_RANGE_SQ := 820.0 * 820.0
const STEER_SLICES := 2
## Half the viewport diagonal at zoom 1.15, plus a small margin. Nothing targets
## or is targeted beyond what the player can see.
const VIEW_RANGE := 620.0

## Isometric projection, applied at the RENDER and INPUT boundaries only.
## Simulation stays flat 2D: the grid, collision, steering, targeting and every
## distance in the tick are unchanged. This is a view transform, not a physics
## change, which is what keeps it cheap and reversible.
##
##   screen.x = (x - y) * K
##   screen.y = (x + y) * K / 2      <- the 2:1 squash
const ISO_K := 0.82

static func to_iso(p: Vector2) -> Vector2:
	return Vector2((p.x - p.y) * ISO_K, (p.x + p.y) * ISO_K * 0.5)

static func from_iso(s: Vector2) -> Vector2:
	var a := s.x / ISO_K
	var b := s.y / (ISO_K * 0.5)
	return Vector2((b + a) * 0.5, (b - a) * 0.5)

## Worms are a chain: a head that steers, and segments that follow the path the
## head actually took rather than beelining at the player. Segments are real
## enemies — individually killable, individually dangerous — but they do not
## steer, and they decohere when their head dies.
const WORM_TYPE := 2
const WORM_TRAIL_LEN := 96
const WORM_SEG_STEPS := 8       # ticks of head history between segments
const WORM_BASE_SEGMENTS := 2   # head + 1 at the start of a run
const WORM_MAX_SEGMENTS := 6
const WORM_GROWTH_SECONDS := 70.0
const SPAWN_RING := 720.0

## Past this from the player, a straggler is brought back around instead of
## trailing forever.
##
## Everything CHASEs, so the swarm converges into one clump behind the player
## and the tail never re-engages — the arena stops feeling surrounded and starts
## feeling like a conga line. Comfortably outside SPAWN_RING so nothing is ever
## moved while it is on screen.
const RECYCLE_RADIUS := 1150.0
## How many may be brought round per tick. A cap, so a player who sprints across
## the arena gets a trickle of re-approaching enemies rather than the whole tail
## blinking to the ring at once.
const RECYCLE_PER_TICK := 3

const PLAYER_RADIUS := 11.0
const IFRAMES := 0.5

const FIRE_BUDGET := 4
const CASCADE_PASSES := 8
## 3 exploits x 4 fires x 600 enemies. The producer set is wider than that
## derivation: the terrain hazard and corruption zones append up to one event per
## enemy per tick, and a mine or packet blast fans out over its own radius. Both
## were dead code until begin_tick moved to the top of the tick, so neither was
## counted here. The worst case still fits, but `append` drops silently past
## capacity (hit_queue.gd), so measure before trusting the margin.
const EVENT_BUDGET := 7200
const BOTNET_BASE_CAP := 8
const BOTNET_BASE_LIFETIME := 12.0
const BOTNET_BASE_RATIO := 0.6

signal level_up_offered(cards: Array)
signal fusion_offered(matches: Array)
## The local slot has resolved its offer and is waiting on `unresolved` others.
signal offer_waiting(unresolved: int)
signal run_ended(won: bool, salvage: int)
signal stats_changed()

var enemies: Population
var projectiles: Population
var shards: Population
var botnet: Population
var grid: Grid
var terrain: Terrain

## Per-enemy slow, owned here rather than by the module pass that will also use
## it: terrain's SLOW zones need it first, and one mechanic with one home is
## worth more than two implementations that drift apart.
var _slow_left: PackedFloat32Array
var _slow_factor: PackedFloat32Array

## CHARGER phases. Named rather than bare integers because the transitions read
## as a sentence and a bare 2 does not.
const CH_APPROACH := 0
const CH_WINDUP := 1
const CH_DASH := 2
const CH_RECOVER := 3

const CHARGE_RANGE := 260.0
const CHARGE_WINDUP := 0.7
## 0.85, not 0.5. At 0.5 a sentinel (speed 78) covered 78 * 3.0 * 0.5 = 117px
## of a 260px commit range — it wound up, lunged a third of the way, and
## stopped short every time. A charge that cannot reach you is a telegraph with
## no threat behind it. 0.85 at 3.6x covers ~239px and carries PAST the player,
## which is what makes sidestepping it feel like sidestepping something.
const CHARGE_DASH := 0.85
const CHARGE_RECOVER := 0.8
const CHARGE_SPEED := 3.6

## How many times a fork_bomb may divide. Three generations, then the leaves die
## for good — the leaf check is what stops one death becoming an unbounded
## cascade that fills the enemy pool.
const SPLIT_GENERATIONS := 3
const FILTER_FRONT_SCALE := 0.10
const MINIBOSS_SALVAGE := 120

## How fast an impulse bleeds off, per second. High enough that a shove is a
## shove rather than a permanent velocity change.
const KNOCK_DECAY := 6.0

## CONE's arc, half-angle in radians. 45 degrees either side of the aim.
const CONE_HALF_ANGLE := 0.785
## Half-width of the beam capsule. The grid query around the capsule midpoint
## uses radius / 2 + BEAM_HALF_WIDTH and filters on centre distance; the
## farthest centre the keep test accepts is a far corner at perpendicular
## offset BEAM_HALF_WIDTH + ENEMY_RADIUS = 34, so the circle covers it iff
## radius / 2 + 22 >= sqrt((radius / 2)^2 + 34^2), i.e. radius >= 30.55.
## test_facing asserts every beam in the tables clears 31.
const BEAM_HALF_WIDTH := 22.0
## A mine sits until something comes within this, then detonates in `radius`.
## The angle between adjacent shots of a split. At 0.22 rad an off-axis shot is
## 0.218*d from the aim line, so against a 16 px combined hit radius
## (PROJECTILE_RADIUS 4 + ENEMY_RADIUS 12) the flanking shots share a target only
## inside ~73 px. That is the intended shape — a spread that covers ground rather
## than three shots stacked on one enemy — not a convergence guarantee.
## How far a homing projectile looks when its bound target dies, and how long it
## waits before looking again after finding nothing.
const HOMING_REACQUIRE := 320.0
const HOMING_RETRY := 0.25
const SPLIT_SPREAD := 0.22
## Equal to MINE_TRIGGER on purpose, so a ring's charges do not sit inside each
## other's fuse radius.
const MINE_SPREAD := 46.0
## How far behind the owner a mine drop is centred: MINE_SPREAD + 40, so a
## three-mine ring's nearest vertex sits exactly 40 behind. Running lays a
## trail behind you.
const MINE_DROP := 86.0
const MINE_TRIGGER := 46.0
const MINE_LIFE := 12.0
## Orbiters circle at this rate, and live exactly one cadence so that firing
## again REPLACES them rather than stacking rings.
const ORBIT_RATE := 2.4
const LOW_INTEGRITY_FRACTION := 0.4

const AFTERIMAGE_RADIUS := 70.0
const AFTERIMAGE_SECONDS := 5.0
const PULSE_PERIOD := 7.0
const PULSE_DAMAGE := 26.0

const MAX_HOSTILES := 200
const HOSTILE_SPEED := 260.0
const HOSTILE_DAMAGE := 6.0
const HOSTILE_RADIUS := 5.0
const RANGED_STANDOFF := 420.0
const RANGED_COOLDOWN := 1.6

const SUPPORT_STANDOFF := 300.0
const SUPPORT_RADIUS := 180.0
const SUPPORT_HEAL := 6.0        # per second

const AM_SUBMERGED := 0
const AM_SURFACING := 1
const AM_ACTIVE := 2
const AMBUSH_UNDER := 2.0
const AMBUSH_SURFACING := 0.6
const AMBUSH_ACTIVE := 4.0
const AMBUSH_SPEED := 2.0

const FLANK_LEAD := 0.9
const FLANK_TANGENT := 0.55

# ------------------------------------------------------------ player slots ---
#
# Players are FOUR fixed parallel-array slots, not nodes and not scalars. Every
# per-player fact below is an array sized SessionRules.MAX_PLAYERS and indexed by
# slot; `local_slot` names the one this process drives, and presentation reads
# that slot explicitly. Only slots named in the session roster become LIVE;
# unused capacity is ABSENT and inert. A reader that wants "the player" must say
# WHICH player — that constraint is what makes the simulation plural.

enum SlotState { LIVE, DEAD, ABSENT }
var slot_state: PackedByteArray

## Each player's actual velocity, derived from the step TAKEN rather than the
## step requested — so it accounts for the arena clamp and for wall slides,
## which is exactly what a flanker needs to aim at.
var player_vel: PackedVector2Array

## Where each slot faces, in WORLD space: the last non-zero applied movement,
## held while it stands still. Forward vectors fire along it. Simulation
## state — hashed and snapshotted — derived from records alone, so every peer
## holds the same value. The local player's facing lags the stick by the
## lockstep delay on purpose: a tick that led the simulation would point where
## the wedge does not fire.
var player_facing: PackedVector2Array

## Per-enemy AI memory. Sized MAX_ENEMIES and reset on every spawn, because
## Population.spawn recycles slots and a stale phase is a live bug — an enemy
## that inherits a mid-dash timer commits to a dash it never wound up for.
var _ai_phase: PackedInt32Array
var _ai_timer: PackedFloat32Array
var _ai_aim: PackedVector2Array
## The LIVE slot each enemy chose this tick, or -1. Decided ONCE in _behave and
## read by the steer range gate, terrain avoidance and reapproach, so the three
## cannot disagree and the nearest-slot scan runs once per enemy rather than
## three times. Per-enemy: reset on spawn, relocated on despawn.
var _enemy_target: PackedInt32Array
## The LIVE positions this tick, packed once after the players move so the hot
## loops scan a ≤4-entry array instead of calling out per entity.
var _live_pos: PackedVector2Array
var _live_of: PackedInt32Array
## The ceiling on healing: an enemy may never be healed above what its type and
## subnet gave it at spawn.
var _spawn_hp: PackedFloat32Array
## execute_below per EXPLOIT, rebuilt on recompile, and the miniboss exemption
## per enemy TYPE — the exemption is a property of what a thing is.
var _execute_by_exploit := PackedFloat32Array()
var _execute_immune_type := PackedByteArray()

## The capture point. Seeded from the run seed so a block schedule reproduces
## from a bug report, and reset per arena — a block belongs to the arena you are
## in, not to the campaign.
var blocks := Blocks.new()
var _block_rng := RandomNumberGenerator.new()

enum CardMode { NORMAL, SEEDED, RANK_ONLY }

## How often a block that cannot fuse still hands you the module you are closest
## to needing. Twenty EXACT triples over a 35-module table are not reachable by
## drawing at random — the targeted card is not a bonus, it is the delivery
## mechanism, so the weight is high on purpose.
const TARGETED_ODDS := 0.70

## The LOCAL slot's open fusion offer as [exploit_index, Recipe] pairs, decoded
## from primitive offer state for presentation. Never simulation state itself.
var _pending_fusions: Array = []

# ------------------------------------------------------------ input ring ---
#
# Every input the simulation consumes — movement AND choices — is a record in
# the lockstep ring, taken one tick at a time above the world guard. The tick
# reads no device, no clock and no connection; it reads records. Solo is a
# one-slot ring at delay zero, ready from tick zero, so offline play consumes
# its own record on the frame it was sampled.
var lockstep: Lockstep
## The tick currently being executed: lockstep.executed at the moment take()
## succeeded, so offer deadlines and every "opened on tick T" fact share one
## clock.
var tick := 0
## Consecutive physics callbacks in which the ring was not ready. Read by the
## HUD to name the slots being waited on.
var _stalled_ticks := 0
## The local slot's staged choice for its open offer, as (card, target, offer
## seq); card -1 means none. Written by the UI-facing choose/decline calls,
## consumed by the next successful record submit.
var _local_choice := Vector3i(-1, -1, -1)
## Caller-owned take buffers so the 60 Hz path allocates nothing.
var _rec_moves: PackedVector2Array
var _rec_cards: PackedInt32Array
var _rec_targets: PackedInt32Array
var _rec_offers: PackedInt32Array

# ---------------------------------------------------------------- offers ---
#
# An offer is PRIMITIVE, PER-SLOT simulation state: a strictly increasing
# sequence number, a kind, its contents as table indices, and a deadline tick.
# Each slot has at most one open offer and a FIFO behind it. A choice is an
# input record whose `offer` field names the open sequence; a stale or bad
# choice is no choice. The card/fusion SIGNALS are presentation notices derived
# from this state for the local slot, never the state itself.
enum OfferKind { LEVEL, SEEDED, RANK_ONLY, FUSION }
var _offer_seq: PackedInt32Array
var _offer_open: Array = []      # per slot: {seq, kind, contents, deadline} or {}
var _offer_queue: Array = []     # per slot: Array of the same rows, deadline -1
## True while a level-up ROUND is in progress: every LIVE slot was given a LEVEL
## offer and not all have resolved. pending_levels counts rounds still owed.
var _round_open := false
## Module encoding for offer contents. Modules are addressed by their index in
## ModuleTable.all(), cached ONCE here because that call builds fresh objects
## every time; fused modules by recipe index; -1 is the salvage card.
var _modules: Array = []
var _module_index: Dictionary = {}
var _recipe_index: Dictionary = {}     # fused module id -> RecipeTable index
const FUSED_BASE := -2
## Out of the entity grid, and therefore untouchable and harmless.
## How lit each enemy is from a hit landed this tick, decayed in _age_fx and
## read by the renderer. Per-enemy, so it needs BOTH halves of the slot
## invariant: zeroed on spawn AND relocated on despawn.
## 0 light / 1 medium / 2 heavy, per enemy TYPE. Indexed by type, not by slot,
## so it needs no relocation.
## One flow field per player slot, each rebuilt when ITS player crosses a cell.
## Read by bosses only — see FlowField's own note on why the swarm does not want
## it — and a boss reads the field of the LIVE slot it is targeting.
var _flow: Array = []
## The LIVE slot the enemy currently being decided is targeting. Set once at the
## top of _behave for the WHOLE decision, so steer direction, range gates,
## terrain avoidance, line of sight, charge aim and hostile lead all agree on
## one target rather than each picking their own.
var _target_slot := 0
var _hit_weight: PackedByteArray
var _hit_flash: PackedFloat32Array
## Seconds of arrival left, per enemy. Non-zero means MATERIALISING: out of the
## grid, not steering, not behaving, not touched by zones, drawn as an effect
## rather than a body.
##
## Kept separate from _submerged rather than folded into it because _ambush
## writes that byte on its own schedule, and kernel_panic is both a mini-boss
## and an AMBUSHER — one flag would have the two states clobbering each other
## depending on tick order.
var _arriving: PackedFloat32Array
## _submerged OR _arriving, rebuilt whole every tick and handed to the grid.
## Rebuilt rather than OR-ed incrementally: an incremental union never clears,
## so an entity stays unqueryable forever after one arrival.
var _no_grid: PackedByteArray
var _submerged: PackedByteArray
## How many times this enemy's line has already divided.
## Knockback impulses, decayed each tick and added to velocity. Separate from
## `force`, which is recomputed from scratch every steer slice and would erase
## an impulse the tick after it landed.
var _knock: PackedVector2Array
var _split_gen: PackedInt32Array
## Paid out already, so a re-dispatched death cannot pay twice.
var _rewarded: PackedByteArray
var _pending_splits: Array = []
## Resolved once: these are table INDICES and looking them up per hit would put
## a linear scan of the enemy table in the damage path.
var _fork_bomb_index := -1
var _packet_filter_index := -1

## Set by the zone pass each tick and read by _eff_clock_speed, so a slow zone
## affects a player without a second timer: standing in it IS the duration. Per
## slot: 1 while standing in a slow zone.
var _zone_slow_player: PackedByteArray

## An absorb pool granted in whole chunks when a shielding exploit fires.
##
## NOT integrity: it does not heal, it does not appear in the integrity ratio,
## and it is spent before armour and defence are ever consulted — a shield is
## something in the way, not toughness. Per slot.
var player_shield: PackedFloat32Array

## ON_LOW_INTEGRITY fires on the CROSSING, not while below the line. Without the
## latch it fires every tick spent under 40%, which is a DPS cliff and, on a
## defensive vector, an infinite shield. Per slot: 1 armed, 0 fired.
var _low_armed: PackedByteArray
var queue: HitQueue
## One Loadout per slot, null where the slot is ABSENT. Compiled into `resolved`
## at slot-strided global ids by _recompile.
var loadouts: Array = []
var director: SpawnDirector

var player_pos: PackedVector2Array
## Each player's position at the END of the previous tick. Same contract as
## Population.prev_pos — see there for why the render layer needs two states.
var player_prev_pos: PackedVector2Array
## Where to DRAW each player this frame: player_prev_pos lerped toward
## player_pos by the frame fraction. Recomputed once per _process and read by
## the camera and _draw, so the ship, the camera and the telegraphs aimed at it
## can never disagree about where it is.
var player_render_pos: PackedVector2Array
## Fraction through the current physics tick, clamped to [0,1]. 1.0 until the
## first _process, so anything that draws before one has run uses the newest
## simulated state rather than an empty past.
var _alpha := 1.0
## The merged base + meta player sheet, one Dictionary per slot. Derived in
## _ready from each roster row's counters, never from a declaration initialiser
## — a player with memory ranks would otherwise start every run at the base 100.
var _sheet: Array = []
var player_health: PackedFloat32Array
var player_iframe: PackedFloat32Array
## Whether ANY slot is still LIVE. The world guard reads this; a later task turns
## the no-LIVE case into a host-confirmed ending barrier.
var alive := true
var won := false
var subnet := 1

## What the run is DOING, as one fact.
##
## This was spread across `paused`, `won` and `_advance_pending`, which between
## them could describe states that cannot exist and could not describe the one
## that now does — cleared, still alive, waiting on the player to walk. The
## director steps in FIGHTING and in no other phase, which is exactly the
## property the old triple kept getting wrong.
## TRANSIT is gone with the corridor Terrain: there is no separate place to be
## any more, only a corridor you walk down that is part of the same arena.
enum Phase { FIGHTING, CLEARED }
var phase := Phase.FIGHTING

## Seconds from the boss kill until the arena is entirely gone. The deadline is
## the point: a cleared subnet you can stand in forever is a lull exactly where
## the run should be at its tensest.
const COLLAPSE_SECONDS := 75.0
var collapse_left := 0.0
## Ticks the corridor collapse has run since the arena finished. Drives the
## threshold past zero into the corridor's negative keys.
var _corridor_collapse_ticks := 0
var _route: PackedInt32Array = PackedInt32Array()
var _route_cell := -1
## director.spawned is per-SUBNET, because director.reset() zeroes it on every
## advance. The campaign total has to survive that.
var _spawned_before := 0

## Banking is INCREMENTAL now a run spans several subnets. SaveGame.bank()
## ACCUMULATES into the save, so handing it the running totals at every subnet
## clear would count subnet 01's kills three times over and hand out unlock
## milestones nobody earned. One primitive dictionary per slot; each process
## persists only its local slot's delta.
var _banked: Array = []

var level := 1
var xp := 0
var xp_needed := _xp_for(1)
var salvage := 0
## Kills and flips are attributed PER SLOT; salvage, level and XP are shared.
var kills: PackedInt32Array
var flips: PackedInt32Array
var pending_levels := 0
var paused := false
## The PLAYER's pause, kept separate from `paused` on purpose. `paused` means
## "a modal offer is open" and four sites clear it unconditionally
## (choose_fusion, decline_fusion, choose_card, decline_card); sharing one bool
## would let a card decline release a pause it never took, and ui.gd's
## `not run.paused` force-hide would then strand a pending fusion.
var user_paused := false
var pickup_radius: PackedFloat32Array
## Presentation state. Pure, and deliberately not part of any simulation step.
var feel := Feel.new()
## Player preference, applied to the composed shake offset. Zero is a supported
## value: screen shake is one of the two effects here that can make a game
## unplayable rather than merely annoying. Loaded from prefs in _ready.
var _shake_pref := 1.0
## Whether floating damage numbers are drawn. Also a preference.
var _numbers_pref := true
## Ground chunks currently falling out of the world: [cell_top_left, elapsed].
## Presentation only — the cell is already void to the simulation the instant it
## is added, so nothing here can change what is walkable.
var _falling: Array = []
## Screen-edge damage flash, 1.0 at the moment of the hit. Read by ui.gd. This
## is the shake-INDEPENDENT damage tell, which is what makes shake = 0 a
## supported setting rather than a way to lose information.
var _vignette := 0.0
## Longest unscaled delta the presentation half will honour. Unclamped, a first
## frame, a scene load or an OS suspend would expire every live effect in one
## step.
const MAX_PRESENT_DT := 0.1
## Ticks of world-freeze still owed to the current hitstop. Decremented above the
## world-step guard; while nonzero the tick runs presentation and input intake
## but steps no simulation. Part of the deterministic tick — no wall clock, no
## process-global time scale — so every peer freezes for the same ticks on the
## same events.
var hitstop_ticks := 0
var _steer_phase := 0
## Diagnostic only: how many times each exploit's vector was emitted this tick.
var _trigger_fires := {}
## Time until each exploit may fire again. INTERVAL uses its own accumulator;
## this gates the EVENT triggers, which previously had no rate limit at all —
## ON_KILL fired once per adjudicated death, so in a swarm it ran continuously
## and was bounded only by the per-tick fire budget.
## One float per exploit. A fire arms it; _step2_integrate decays it. While it is
## live, that exploit's ward_* values count toward the player's effective stats —
## as a MAX across exploits, never a sum, because the same module is legal in
## several slots and summing would buy magnitude at no uptime cost.
var _ward_left: PackedFloat32Array
## Seconds until this exploit may grant its shield pool again; 0 means now.
var _shield_left: PackedFloat32Array
var _fire_cd: PackedFloat32Array
## Transient shot visuals. BROADCAST, BEAM and CHAIN resolve straight through
## the hit queue and drew nothing at all — you saw enemies die with no sign of
## what killed them. Bounded by the fire budget: 3 exploits x 4 fires x FX_LIFE
## worth of ticks.
const FX_LIFE := 0.13
## Hit flash fades in about a sixth of a second — long enough to read at 60fps,
## short enough that a swarm under fire is not a white blob.
const HIT_FLASH_DECAY := 6.0

## How a chunk of floor leaves. Gravity in screen pixels: the drop accelerates,
## because a tile that slides down at a constant rate reads as a fade rather
## than as a fall.
const FALL_GRAVITY := 900.0
const FALL_LIFE := 1.6
const FALL_HEIGHT := 20.0
## Chunks alive at once. The collapse voids a whole frontier at a time and an
## uncapped list would draw the entire arena's worth of boxes on the last tick.
const MAX_FALLING := 220

## Indexed by the weight class in _hit_weight.
const HIT_SOUNDS := ["hit_light", "hit_medium", "hit_heavy"]

## A boss entrance, in two phases. The charge is long enough to read and move
## out of; the pop is short enough to feel like an impact rather than a fade.
## Not interruptible and not skippable — an arrival you can shoot through is not
## an entrance.
const ARRIVAL_CHARGE := 0.9
const ARRIVAL_POP := 0.25
const ARRIVAL_TOTAL := ARRIVAL_CHARGE + ARRIVAL_POP
## Transient fire visuals, one list, one entry per fire — except CHAIN, which
## appends one BOLT per resolved link, and the two non-fire rings (an arrival
## flash, kernel_panic's telegraph). MINE and ORBIT fires append nothing: they
## show through the glyphs and the orbiter trail. An estimate for the reader,
## not a capacity (the Array is unbounded, aged by life): per LIVE slot about
## 3 exploits x max(FIRE_BUDGET, BURST_MAX) x (max chain_count + 1) entries.
## Entry: [kind, at, dir, radius, life, colour]. `dir` is a unit facing with
## `radius` the length for DASH, BEAM and WEDGE, and the full link OFFSET
## (to - from) for BOLT.
enum FxKind { RIPPLE, DASH, BOLT, BEAM, WEDGE, PULSE, BLAST }
var _fx: Array = []
var _order: PackedInt32Array
var _band_count: PackedInt32Array
const DEPTH_BANDS := 192

var thresholds: PackedFloat32Array
var enemy_types: Array
## Every slot's compiled exploits in ONE flat array of MAX_PLAYERS x MAX_EXPLOITS
## entries, indexed by global id `gid = slot * GID_STRIDE + exploit_index`.
## Entries are null where a slot has no exploit there. Projectile owners, hit
## queue sources, and the per-exploit arrays below all carry gids, so an event's
## owning build is one decode away and never confused between players.
var resolved: Array = []
const GID_STRIDE := Loadout.MAX_EXPLOITS
var _fire_acc: PackedFloat32Array
var _proj_owner: PackedInt32Array
var _proj_pierce: PackedInt32Array
var _proj_last: PackedInt32Array
## Remaining flight distance. This is the ONLY lifetime bound on a projectile.
## The old player-relative 1600-unit cull is gone: it was measured FROM THE
## PLAYER, so fleeing at a legal buffed clock_speed could cull a max-reach packet
## early and make reach silently inert exactly when you run away. Max travel is
## 832px, so projectiles now live shorter than they used to, not longer.
var _proj_dist_left: PackedFloat32Array
## A homing projectile binds its target ONCE, at spawn, and re-acquires only
## when that target dies. The naive version — a grid query per projectile per
## tick — is a second broadcast query per shot per frame, and it is what would
## move the perf gate. The generation guards a recycled slot; _proj_reacquire
## backs a miss off, or a shot over cleared ground re-queries every tick.
var _proj_target: PackedInt32Array
var _proj_target_gen: PackedInt32Array
var _proj_reacquire: PackedFloat32Array
## Mines and orbiters borrow the projectile population. Zero means "an ordinary
## projectile", so no branch is needed for the common case.
var _mine_left: PackedFloat32Array
var _orbit_left: PackedFloat32Array
var _orbit_phase: PackedFloat32Array
var _worm_id: PackedInt32Array
var _worm_seg: PackedInt32Array
var _worm_trail := {}          # worm id -> PackedVector2Array ring buffer
var _worm_cursor := {}         # worm id -> write index
var _next_worm_id := 1
var _botnet_ratio: PackedFloat32Array
var _botnet_life: PackedFloat32Array

var _buf: PackedInt32Array
## Beam selection scratch: the kept candidates and their projections, sized
## like _buf so the tick allocates nothing. Not simulation state.
var _beam_hits: PackedInt32Array
var _beam_keys: PackedFloat32Array
var _counts: PackedInt32Array
## Enemy fire.
##
## A second Population, and deliberately NOT in the entity grid: the only thing
## a hostile shot can hit is the player, so detection is one distance test per
## shot per tick rather than a grid insert plus a query. That also leaves the
## grid's tag space and rebuild cost untouched.
var hostiles: Population
var _hostile_life: PackedFloat32Array

var _pos_arrays: Array
var _skips: Array
## The module set each slot may draw cards from, derived from its counters.
var _unlocked: Array = []
## Headless tests drive the local player through this instead of the keyboard.
var input_override = null
## Set by a headless driver BEFORE the node enters the tree: the engine's own
## physics callback is disabled at ready, so every tick is the driver's explicit
## call. Godot re-enables _physics_process at ready, which is why a driver
## cannot simply clear it beforehand — and a stray engine tick would submit a
## record the driver then cannot replace.
var external_drive := false
## One WORLD direction per player slot. The local one is written once per tick
## by _poll_local_input, above the guard; read by the simulation from nowhere
## else. This is the seam a networked peer drives: a remote player is a slot
## whose entry arrives in a packet instead of from the InputMap, and the tick
## cannot tell the difference — which is the whole point.
var inputs: PackedVector2Array
var _rng := RandomNumberGenerator.new()
## One card/offer stream per POSSIBLE player slot, seeded independently from the
## descriptor. A player's card shuffles and block-payout rolls draw from their
## own slot's stream, so one player opening a card screen cannot shift the
## sequence another player sees. The shared simulation randomness — fork-bomb
## child offsets, miniboss spawn angles, shard scatter — lives on `_rng`.
var _card_rng: Array = []

## The immutable session this run derives itself from, and this peer's slot in
## it. Set by configure_session before _ready, or defaulted to a one-slot solo
## session when absent. Every RNG seed and every player's starting build is a
## function of descriptor.seed and the roster counters, nothing else.
var _session: NetworkSession = null
var local_slot := 0

## Stable per-stream salts added to descriptor.seed. Chosen so the shared and
## slot-zero streams reproduce the historical fixed seeds exactly — the solo
## campaign is bit-for-bit what it was — while each further card slot gets a
## well-separated stream. No stream calls randomize().
const _SEED_SIM := 0
const _SEED_BLOCK := 1
const _SEED_DIRECTOR := -1
const _SEED_TERRAIN := 0
const _SEED_CARD_STEP := 97

## The base seed a solo run derives every stream from. Chosen so the per-stream
## salts above reproduce the historical fixed seeds, keeping the offline campaign
## bit-for-bit unchanged. A network run gets its seed from the host instead.
const DEFAULT_SEED := 20260830

var _mm_enemy: MultiMeshInstance2D
var _mm_proj: MultiMeshInstance2D
var _mm_shard: MultiMeshInstance2D
var _mm_botnet: MultiMeshInstance2D
var _camera: Camera2D

# ---------------------------------------------------------------- the view ---
#
# The slot this SCREEN looks through: the local slot while it is LIVE, else a
# spectate target — the next LIVE slot in ascending order from the last one,
# or the local slot itself when nobody is LIVE. The camera, the culling
# rectangle and the depth bands follow it; the simulation never does — enemies
# target by census, and this is never hashed or snapshotted.

var view_slot := 0
var _spectate := -1

## One hue per screen-relative slot: index 0 is the local player's own hue,
## unchanged from solo; teammates take the rest in a fixed order, so a given
## teammate is the same colour on every frame of this screen.
const TEAM_HUES := [Color(0.9, 1.8, 1.3), Color(1.8, 1.4, 0.6),
	Color(1.1, 1.0, 1.9), Color(1.9, 0.9, 1.3)]
const HURT_HUE := Color(1.9, 0.8, 0.8)
const ABSENT_ALPHA := 0.35

func _next_live_from(from: int) -> int:
	for k in range(1, SessionRules.MAX_PLAYERS + 1):
		var s := (from + k) % SessionRules.MAX_PLAYERS
		if slot_state[s] == SlotState.LIVE:
			return s
	return -1

func _refresh_view() -> void:
	if slot_state[local_slot] == SlotState.LIVE:
		view_slot = local_slot
		_spectate = -1
		return
	if _spectate >= 0 and slot_state[_spectate] == SlotState.LIVE:
		view_slot = _spectate
		return
	_spectate = _next_live_from(local_slot)
	view_slot = _spectate if _spectate >= 0 else local_slot

## Confirm, with no offer owning it and this slot not LIVE: look through the
## next LIVE slot. Returns whether the view moved.
func cycle_spectate() -> bool:
	if slot_state[local_slot] == SlotState.LIVE:
		return false
	var n := _next_live_from(view_slot)
	if n < 0 or n == view_slot:
		return false
	_spectate = n
	view_slot = n
	return true

## The hue a slot wears on THIS screen.
func slot_hue(slot: int) -> Color:
	return TEAM_HUES[(slot - local_slot + SessionRules.MAX_PLAYERS) % SessionRules.MAX_PLAYERS]

## What the player pass draws, as [slot, colour, alpha, name]: every LIVE slot,
## the local one nameless in its own hue and a teammate in its hue with a name
## tag; an ABSENT slot dimmed where it parked; a DEAD slot not at all.
func player_draw_list() -> Array:
	var out := []
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.DEAD:
			continue
		var row := _session.profile(s)
		if row.is_empty():
			continue
		var name := ""
		if s != local_slot:
			name = String(row.get("name", ""))
			if name == "":
				name = "slot %d" % s
		if slot_state[s] == SlotState.ABSENT:
			out.append([s, slot_hue(s), ABSENT_ALPHA, name + " (away)"])
			continue
		var c := slot_hue(s)
		if player_iframe[s] > 0.0:
			c = HURT_HUE
		out.append([s, c, 1.0, name])
	return out

## Bind the session this run derives itself from. Must be called before the node
## enters the tree, i.e. before _ready. Tests and the lobby use it; absent it,
## _ready builds a one-slot solo session so offline play needs no setup.
func configure_session(session: NetworkSession) -> void:
	_session = session

## The live transport, handed over by the lobby before _ready and reparented
## under this node. Polled ABOVE the world guard only; nothing below it, and
## nothing in input application, ever inspects it. Solo has none.
var _transport: Transport = null

func attach_transport(transport: Transport) -> void:
	_transport = transport
	transport.snapshot_received.connect(_on_snapshot)
	transport.peer_left.connect(_on_peer_left)
	transport.peer_joined.connect(_on_peer_joined)

# ------------------------------------------------------- parking, reconnect ---
#
# Roster changes are keyed by the TICK they apply at, never by arrival: the
# host names the tick, every peer applies the change at that tick, so a
# parked or returning slot is the same slot on every machine.

## The health a slot parked with, or -1 while it is not parked. ABSENT
## overwrites the sole slot_state, so this is what a return reads to decide
## LIVE or DEAD. Simulation state: hashed and snapshotted.
var _parked_health: PackedFloat32Array
## Host: slots whose controller is gone, to park at the first missing tick.
var _pending_park: Dictionary = {}
## slot -> T: apply ABSENT before consuming T.
var _pending_absent: Dictionary = {}
## slot -> T: apply PRESENT after consuming T. On a returnee this is the
## buffered PRESENT that arrived ahead of the snapshot: it cannot apply while
## the world is held for the restore, and it survives the restore because
## the manifest does not carry it.
var _pending_present: Dictionary = {}
## Host: reconnect HELLOs waiting for a free boundary, as [body, peer].
var _pending_hello: Array = []
var _reconnect_attempts := 0
var _reconnect_frames := 0
## Host: the last snapshot it serialised and the boundary it was for. The
## wire carries it; the suites, which pump the wire by hand, read it here.
var last_snapshot := PackedByteArray()
var last_snapshot_tick := -1
const RECONNECT_ATTEMPTS := 10
const RECONNECT_RETRY_FRAMES := 180

func _on_peer_left(id: int) -> void:
	if _session.ended:
		return
	if _session.role == NetworkSession.Role.HOST:
		if _transport != null and _transport.slot_of_peer.has(id):
			request_park(int(_transport.slot_of_peer[id]))
		if not _session.reconnect.is_empty() and int(_session.reconnect["peer"]) == id:
			abort_reconnect()
	elif _session.role == NetworkSession.Role.CLIENT:
		_begin_reconnect()

func _on_peer_joined(_id: int) -> void:
	if _session.role != NetworkSession.Role.CLIENT or not _session.reconnecting \
			or _transport == null:
		return
	_transport.bind_peer(Transport.HOST_PEER, 0)
	var p := _session.profile(local_slot)
	_transport.send_control(Protocol.Message.HELLO, 0, {
		"protocol": SessionRules.PROTOCOL, "name": p.get("name", ""),
		"counters": p.get("counters", {}),
		"session_id": int(_session.descriptor.get("session_id", 0)),
		"slot": local_slot})

## Client: the host is gone, or silent past the timeout. Stop, and HELLO for
## this original slot until it works or the attempts run out. There is no
## host migration.
func _begin_reconnect() -> void:
	if _session.role != NetworkSession.Role.CLIENT or _session.ended:
		return
	_session.reconnecting = true
	_reconnect_frames = 0
	_reconnect_attempts += 1
	if _reconnect_attempts > RECONNECT_ATTEMPTS:
		_session.ended = true
		emit_signal("run_ended", false, 0)
		return
	if _transport != null:
		_transport.rejoin()

## A rejoin that never connects raises no signal; retry on a frame count.
## Above the guard and off the tick: reconnecting is transport, not simulation.
func _reconnect_step() -> void:
	if not _session.reconnecting or _transport == null:
		return
	if _transport.connected():
		_reconnect_frames = 0
		return
	_reconnect_frames += 1
	if _reconnect_frames >= RECONNECT_RETRY_FRAMES:
		_begin_reconnect()

## Host: this slot's controller is gone. It parks at the first tick the host
## holds no record for — every record it did send is relayed and applied.
func request_park(slot: int) -> void:
	if slot_state[slot] != SlotState.ABSENT:
		_pending_park[slot] = true

func _host_park_step() -> void:
	for slot in _pending_park.keys():
		if _pending_present.has(slot):
			continue                        # its return is announced: judge it after
		if slot_state[slot] == SlotState.ABSENT:
			_pending_park.erase(slot)
			continue
		if lockstep.has_record(slot, lockstep.executed):
			continue
		var t := lockstep.executed
		_pending_park.erase(slot)
		_pending_absent[slot] = t
		if _transport != null:
			_transport.send_control(Protocol.Message.ABSENT, t, {"slot": slot})
			if _transport.peer_of_slot.has(slot):
				_transport.drop_peer(int(_transport.peer_of_slot[slot]))

## Every peer, before consuming T: the slot leaves. Its health is remembered,
## its offers resolve, its progress banks once — the watermark on every peer,
## the save only where the slot is local — and if it was the last LIVE slot
## the run has a loss candidate.
func _park(slot: int) -> void:
	if slot_state[slot] == SlotState.ABSENT:
		return
	_parked_health[slot] = player_health[slot]
	slot_state[slot] = SlotState.ABSENT
	player_vel[slot] = Vector2.ZERO
	inputs[slot] = Vector2.ZERO
	_session.absent_ticks[slot] = lockstep.executed
	_resolve_offer_on_slot_exit(slot)
	_bank_slot(slot, false)
	var was := alive
	alive = _any_live()
	if was and not alive:
		_terminal(NetworkSession.Outcome.LOSS)

## Every peer, after consuming T: the slot is back. Positive parked health
## places it on open ground beside the LIVE slot nearest the arena centre, or
## at the centre when nobody is LIVE, marks it LIVE and requires it from T + 1
## — with neutral records primed through T + delay, because its own sampling
## begins only after the restore. Zero parked health returns it DEAD: a
## spectator, never required, and any ending check stays open.
func _return(slot: int, t: int) -> void:
	if slot_state[slot] != SlotState.ABSENT:
		return
	# A return faces right, whether it comes back LIVE or DEAD, so a slot
	# revived later never carries the facing it parked with.
	player_facing[slot] = Vector2.RIGHT
	var h := _parked_health[slot]
	_parked_health[slot] = -1.0
	if h > 0.0:
		var centre: Vector2 = terrain.arena().get_center()
		var anchor := centre
		var best := INF
		for s in SessionRules.MAX_PLAYERS:
			if slot_state[s] == SlotState.LIVE:
				var d := player_pos[s].distance_squared_to(centre)
				if d < best:
					best = d
					anchor = player_pos[s]
		player_pos[slot] = terrain.nearest_open(anchor)
		player_prev_pos[slot] = player_pos[slot]
		player_render_pos[slot] = player_pos[slot]
		player_vel[slot] = Vector2.ZERO
		player_iframe[slot] = 0.0
		player_health[slot] = h
		slot_state[slot] = SlotState.LIVE
		lockstep.mark_live(slot)
		lockstep.prime_slot(slot, t + 1, t + lockstep.delay)
		# Somebody is LIVE again: whatever no-LIVE verdict this peer held is
		# void. A win stands.
		if _session.end_outcome == NetworkSession.Outcome.LOSS:
			_session.end_outcome = NetworkSession.Outcome.NONE
	else:
		player_health[slot] = 0.0
		slot_state[slot] = SlotState.DEAD
		lockstep.mark_present(slot)
		lockstep.mark_dead(slot)
	alive = _any_live()
	if _session.role == NetworkSession.Role.HOST:
		_session.clear_latch()
		_session.last_present_tick = t
		# A DEAD returnee is in the PRESENT roster from here, but it cannot
		# report for a check tick it never reached: the open check is reissued
		# at a fresh tick so its report counts.
		if _session.end_check_tick >= 0 and slot_state[slot] == SlotState.DEAD:
			_session.clear_end_check()
			_session.end_candidate_pending = _session.end_outcome != NetworkSession.Outcome.NONE

## Host: a HELLO after START. Accepted only for this session, an ABSENT slot
## the roster holds, and before END; then the return is announced at a fresh
## boundary R: RESYNC(R) — flagged when it clears a no-LIVE barrier — and
## PRESENT(slot, R) to everyone, WELCOME with the immutable descriptor to the
## returnee. Returns the slot, or -1 when refused.
func accept_reconnect(body: Dictionary, peer: int) -> int:
	var es := _session
	if es.ended or es.recovering() or not es.reconnect.is_empty():
		return -1
	var slot := es.admit(body, peer)
	if slot < 0 or slot_state[slot] != SlotState.ABSENT or _parked_health[slot] < 0.0:
		if _transport != null:
			_transport.drop_peer(peer)
		return -1
	var r := lockstep.executed + lockstep.delay + Protocol.BOUNDARY_MARGIN
	es.reconnect = {"slot": slot, "peer": peer, "tick": r}
	if _parked_health[slot] > 0.0 and not _any_live():
		es.pending_live_return = [slot, r]
	# Only a LIVE return voids a no-LIVE barrier. A DEAD one leaves it standing
	# and joins its roster.
	var clears := _parked_health[slot] > 0.0 and es.end_check_tick >= 0 \
		and es.end_outcome != NetworkSession.Outcome.WIN
	if clears:
		es.cancel_no_live_check()
	es.announce_resync(r, PackedInt32Array([slot]))
	_pending_present[slot] = r
	if _transport != null:
		_transport.send_control(Protocol.Message.WELCOME, 0,
			{"descriptor": es.descriptor, "slot": slot}, peer)
		_transport.send_control(Protocol.Message.RESYNC, r, {"clears_end": clears})
		_transport.send_control(Protocol.Message.PRESENT, r, {"slot": slot})
	return slot

## Host: the returnee vanished before its boundary. The latch clears and
## no-LIVE is judged again at once; PRESENT was already announced, so the
## slot returns unmanned at R + 1 and parks again at its first missing tick.
func abort_reconnect() -> void:
	var es := _session
	if es.reconnect.is_empty():
		return
	var slot := int(es.reconnect["slot"])
	es.reconnect = {}
	es.clear_latch()
	_pending_park[slot] = true
	if not _any_live() and es.end_outcome == NetworkSession.Outcome.LOSS:
		es.end_candidate_pending = true

func _host_hello_step() -> void:
	while not _pending_hello.is_empty():
		if _session.recovering() or not _session.reconnect.is_empty():
			return
		var e: Array = _pending_hello.pop_front()
		accept_reconnect(e[0], int(e[1]))

## The roster changes due this tick, above the guard: parks before the tick
## they name is consumed, returns after.
func _roster_step() -> void:
	if _session.role == NetworkSession.Role.HOST:
		_host_park_step()
		_host_hello_step()
	for slot in _pending_absent.keys():
		if lockstep.executed >= int(_pending_absent[slot]):
			_pending_absent.erase(slot)
			_park(slot)
	for slot in _pending_present.keys():
		var t := int(_pending_present[slot])
		if lockstep.executed >= t + 1:
			_pending_present.erase(slot)
			_return(slot, t)

# ---------------------------------------------------------------- recovery ---
#
# Desync recovery, host-authoritative. Every CHECKSUM_INTERVAL ticks each peer
# reports a hash; the host's ring compares them. On the first disagreement the
# host names a FUTURE boundary R = executed + delay + 3, tells everyone, keeps
# simulating, and when it has executed exactly through R — with every LIVE
# slot's records for (R, R + delay] in hand — it serialises once and sends the
# snapshot only to the peers that disagreed. Those restore to the state after
# R and resume at R + 1; everyone else never rewinds. The host is the
# authority: if it is the one that diverged, the others are brought to it.
# Three divergences end the session with every offending tick in the report.
#
# These methods are driven by the tick above the guard when a transport is
# attached, and directly by the recovery suite, which pumps messages by hand.

## Host: look for a divergence and announce a boundary. Returns the boundary
## tick announced this call, or -1.
func host_detect_desync() -> int:
	if _session.role != NetworkSession.Role.HOST or _session.terminated:
		return -1
	var d := lockstep.desync_at()
	if d < 0:
		return -1
	# Which slots disagreed with the host at that tick.
	var rec: Dictionary = lockstep._checksums[d]
	var hashes: PackedInt64Array = rec["hashes"]
	var mask := int(rec["mask"])
	var mine := hashes[local_slot] if (mask & (1 << local_slot)) != 0 else 0
	var targets := PackedInt32Array()
	for s in SessionRules.MAX_PLAYERS:
		if (mask & (1 << s)) != 0 and s != local_slot and hashes[s] != mine:
			targets.append(s)
	lockstep.prune_checksums(d)
	if _session.record_desync(d):
		_terminate()
		return -1
	var r := lockstep.executed + lockstep.delay + Protocol.BOUNDARY_MARGIN
	_session.announce_resync(r, targets)
	if _transport != null:
		_transport.send_control(Protocol.Message.RESYNC, r, {"clears_end": false})
	return r

## Any peer: a boundary was announced. Records past it are retained by the
## transport until the boundary resolves.
func announce_resync(r: int) -> void:
	if _session.announce_resync(r) and _transport != null:
		_transport.arm_boundary(r)

## Host: serialise for the active boundary once it has executed exactly through
## R and holds the window. Returns the snapshot bytes when produced this call,
## an empty array otherwise. Sends the snapshot to each target peer when a
## transport is attached.
func host_try_snapshot() -> PackedByteArray:
	var r := _session.resync_tick
	if r < 0 or _session.resync_sent or lockstep.executed != r + 1:
		return PackedByteArray()
	if not lockstep.has_window(r):
		return PackedByteArray()
	var bytes := serialize_state(r)
	_session.resync_sent = true
	last_snapshot = bytes
	last_snapshot_tick = r
	# A returning peer joins the relay set in the SAME frame the state is
	# serialised, so no relayed record falls between the snapshot and the
	# first relay it receives.
	if not _session.reconnect.is_empty() and int(_session.reconnect["tick"]) == r:
		if _transport != null:
			_transport.bind_peer(int(_session.reconnect["peer"]), int(_session.reconnect["slot"]))
		_session.reconnect = {}
	if _transport != null:
		for s in _session.resync_targets:
			if _transport.peer_of_slot.has(s):
				_transport.send_snapshot(int(_transport.peer_of_slot[s]), r, bytes)
	# The host's part is done; a queued repair becomes active.
	_session.clear_resync()
	return bytes

## Any peer: a snapshot for boundary R. A successful restore resumes at R + 1
## with every retained record merged; a refused one leaves the run untouched.
func apply_snapshot(bytes: PackedByteArray, r: int) -> bool:
	if not restore_state(bytes, r):
		return false
	if _transport != null:
		_transport.release_boundary()
	_session.clear_resync()
	# A returnee is back in the session the moment its restore commits.
	_session.reconnecting = false
	_reconnect_attempts = 0
	return true

func _on_snapshot(tick_label: int, bytes: PackedByteArray) -> void:
	apply_snapshot(bytes, tick_label)

## The per-tick recovery bookkeeping, above the guard. The host holds at R + 1
## until it can serialise; a correct client drops its boundary once the window
## is behind it and no snapshot came.
func _recovery_step() -> void:
	if _session.role == NetworkSession.Role.HOST:
		host_detect_desync()
		host_try_snapshot()
	elif _session.resync_tick >= 0 \
			and lockstep.executed > _session.resync_tick + lockstep.delay + Lockstep.RING / 2:
		if _transport != null:
			_transport.release_boundary()
		_session.clear_resync()

## Whether the host must hold this tick: it has executed through R and is
## waiting for the window to fill before it can serialise state-after-R.
func _holding_for_snapshot() -> bool:
	return _session.role == NetworkSession.Role.HOST and _session.resync_tick >= 0 \
		and not _session.resync_sent and lockstep.executed == _session.resync_tick + 1

## Three divergences: the session is over. The host says so; the world stops.
func _terminate() -> void:
	_session.terminated = true
	_session.ended = true
	if _transport != null and _transport.is_host:
		_transport.send_control(Protocol.Message.END, tick,
			{"outcome": NetworkSession.Outcome.TERMINATED, "hash": 0})
	emit_signal("run_ended", false, 0)

# ------------------------------------------------------------------ ending ---
#
# `run_ended` has exactly two sources: the solo candidate tick, and the host's
# END. Every terminal state a peer reaches in a session is a CANDIDATE — the
# world holds below the guard, lockstep keeps consuming above it, this peer's
# records go neutral — and the host confirms it through every PRESENT peer's
# report at a future check tick. A false local ending is therefore repaired,
# not announced. These methods are driven by the tick when a transport is
# attached and directly by the ending suite, which pumps messages by hand.

## A terminal state was reached here: nobody LIVE, or the campaign won.
func _terminal(outcome: int) -> void:
	var es := _session
	if es.ended or es.terminated:
		return
	if es.role == NetworkSession.Role.SOLO:
		# Nobody to confirm with: solo ends on the candidate tick.
		es.ended = true
		es.end_outcome = outcome
		emit_signal("run_ended", outcome == NetworkSession.Outcome.WIN,
			salvage if outcome == NetworkSession.Outcome.WIN else 0)
		return
	es.end_outcome = outcome
	if es.role == NetworkSession.Role.HOST:
		# A no-LIVE verdict is suppressed while a LIVE return is latched: the
		# returning slot will make somebody LIVE at its boundary.
		if outcome == NetworkSession.Outcome.LOSS and es.latched():
			return
		es.end_candidate_pending = true
	elif _transport != null:
		_transport.send_control(Protocol.Message.END_CANDIDATE, tick,
			{"outcome": outcome, "hash": 0})

## Slots other than this one whose controller is PRESENT (LIVE or DEAD).
func _present_remote_count() -> int:
	var n := 0
	for s in SessionRules.MAX_PLAYERS:
		if s != local_slot and slot_state[s] != SlotState.ABSENT:
			n += 1
	return n

## Host: a client's END_CANDIDATE, or — when its tick names the open check —
## that client's report for it.
func receive_end_candidate(slot: int, at_tick: int, outcome: int, hash_value: int) -> void:
	var es := _session
	if es.end_check_tick >= 0 and at_tick == es.end_check_tick:
		es.end_reports[slot] = [hash_value, outcome]
		return
	# A no-LIVE candidate is refused while a LIVE return is latched, and stale
	# when it names a tick at or before the last PRESENT — equality included,
	# because PRESENT(T) applies only after T is consumed. A win is neither.
	if outcome == NetworkSession.Outcome.LOSS \
			and (es.latched() or at_tick <= es.last_present_tick):
		return
	es.end_candidate_pending = true

## Any peer: the host opened a check at C.
func receive_end_check(c: int) -> void:
	_session.open_end_check(c)

## A client: the host confirmed. This is the one place a session emits
## run_ended.
func receive_end(_c: int, outcome: int) -> void:
	var es := _session
	if es.ended:
		return
	es.ended = true
	if outcome == NetworkSession.Outcome.TERMINATED:
		es.terminated = true
		emit_signal("run_ended", false, 0)
		return
	emit_signal("run_ended", outcome == NetworkSession.Outcome.WIN,
		salvage if outcome == NetworkSession.Outcome.WIN else 0)

## Host: END. Reliable, to everyone, once.
func _confirm_end(outcome: int) -> void:
	var es := _session
	var c := es.end_check_tick
	es.ended = true
	es.clear_end_check()
	es.end_candidate_pending = false
	if _transport != null:
		_transport.send_control(Protocol.Message.END, c, {"outcome": outcome, "hash": 0})
	emit_signal("run_ended", outcome == NetworkSession.Outcome.WIN,
		salvage if outcome == NetworkSession.Outcome.WIN else 0)

## Host: judge the open check once every PRESENT slot has reported. Returns
## "" while waiting, "end" when it confirmed, "clear" when everyone agreed
## nobody is terminal, and "resync" when it scheduled a repair.
func evaluate_end_check() -> String:
	var es := _session
	var c := es.end_check_tick
	if c < 0 or not es.end_reports.has(local_slot):
		return ""
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] != SlotState.ABSENT and not es.end_reports.has(s):
			return ""
	var mine: Array = es.end_reports[local_slot]
	var targets := PackedInt32Array()
	for s in SessionRules.MAX_PLAYERS:
		if s == local_slot or not es.end_reports.has(s):
			continue
		var r: Array = es.end_reports[s]
		if r[0] != mine[0] or r[1] != mine[1]:
			targets.append(s)
	if targets.is_empty():
		if es.end_outcome != NetworkSession.Outcome.NONE:
			_confirm_end(es.end_outcome)
			return "end"
		es.clear_end_check()
		es.end_candidate_pending = false
		return "clear"
	# Disagreement: the authority rule at a FRESH future boundary — the host may
	# already be past C and keeps no snapshot of it. A terminal host repairs the
	# others to its terminal state and checks again; a nonterminal host repairs
	# the false-ending client and play resumes.
	es.clear_end_check()
	if es.record_desync(c):
		_terminate()
		return "terminated"
	var r := lockstep.executed + lockstep.delay + Protocol.BOUNDARY_MARGIN
	es.announce_resync(r, targets)
	if _transport != null:
		_transport.send_control(Protocol.Message.RESYNC, r, {"clears_end": false})
	es.end_candidate_pending = es.end_outcome != NetworkSession.Outcome.NONE
	return "resync"

## The per-tick ending bookkeeping, above the guard: report at C + 1, and, as
## host, open checks for candidates and judge the open one.
func _ending_step() -> void:
	var es := _session
	if es.role == NetworkSession.Role.SOLO or es.ended or es.terminated:
		return
	if es.end_check_tick >= 0 and not es.end_reported \
			and lockstep.executed == es.end_check_tick + 1:
		es.end_reported = true
		var h := _state_hash()
		es.end_report = [es.end_check_tick, h, es.end_outcome]
		if es.role == NetworkSession.Role.HOST:
			receive_end_candidate(local_slot, es.end_check_tick, es.end_outcome, h)
		elif _transport != null:
			_transport.send_control(Protocol.Message.END_CANDIDATE, es.end_check_tick,
				{"outcome": es.end_outcome, "hash": h})
	if es.role != NetworkSession.Role.HOST:
		return
	if es.end_check_tick < 0:
		if es.end_candidate_pending and not es.recovering() \
				and not (es.latched() and es.end_outcome != NetworkSession.Outcome.WIN):
			if _present_remote_count() == 0:
				# Nobody to confirm with: the host's own candidate is the verdict.
				if es.end_outcome != NetworkSession.Outcome.NONE:
					es.open_end_check(tick)
					_confirm_end(es.end_outcome)
				else:
					es.end_candidate_pending = false
				return
			var c := lockstep.executed + lockstep.delay + Protocol.BOUNDARY_MARGIN
			es.open_end_check(c)
			if _transport != null:
				_transport.send_control(Protocol.Message.END_CHECK, c, {})
		return
	evaluate_end_check()

## The LIVE slots whose record for the next tick has not arrived, for the HUD's
## stall notice once _stalled_ticks passes STALL_NOTICE.
func missing_slots() -> PackedInt32Array:
	return lockstep.missing(lockstep.executed)

## A one-slot solo session carrying this profile's own counters, the default
## seed, delay zero, and no choice timeout.
func _default_solo_session() -> NetworkSession:
	var profile := {
		"slot": 0,
		"name": "",
		"counters": SaveGame.session_counters(),
	}
	var desc := NetworkSession.validate_descriptor(
		NetworkSession.solo_descriptor(profile, DEFAULT_SEED))
	return NetworkSession.create(desc, 0, NetworkSession.Role.SOLO)

func _ready() -> void:
	if _session == null:
		configure_session(_default_solo_session())
	local_slot = _session.local_slot
	var base: int = int(_session.descriptor.get("seed", 0))
	_rng.seed = base + _SEED_SIM
	_block_rng.seed = base + _SEED_BLOCK
	_card_rng.resize(SessionRules.MAX_PLAYERS)
	for s in SessionRules.MAX_PLAYERS:
		var cr := RandomNumberGenerator.new()
		cr.seed = base + s * _SEED_CARD_STEP
		_card_rng[s] = cr
	enemy_types = EnemyTable.all()
	thresholds = PackedFloat32Array()
	thresholds.resize(enemy_types.size())
	_refresh_thresholds()
	for i in enemy_types.size():
		thresholds[i] = enemy_types[i].corruption_threshold

	# A window that follows the PARTY, not the arena. See Grid._init: every query
	# in this game is near a player, so indexing the whole map spends per-tick
	# work on ground nobody is standing on. Preallocated for the MAX_WINDOW cap a
	# fully spread party needs; the live rect is sized down to the party's
	# bounding box each tick, so solo still rebuilds a 3200 square.
	grid = Grid.new(Vector2.ZERO,
		Vector2(SessionRules.MAX_WINDOW, SessionRules.MAX_WINDOW), CELL,
		MAX_ENEMIES + MAX_PROJECTILES + MAX_SHARDS + MAX_BOTNET + 1)
	enemies = Population.new(MAX_ENEMIES)
	projectiles = Population.new(MAX_PROJECTILES)
	shards = Population.new(MAX_SHARDS)
	botnet = Population.new(MAX_BOTNET)
	hostiles = Population.new(MAX_HOSTILES)
	_hostile_life = PackedFloat32Array(); _hostile_life.resize(MAX_HOSTILES)
	# Four players can generate four parties' worth of events in one tick, so the
	# event budget scales with the player cap. Sized generously enough that
	# queue.dropped stays zero even at the worst-case fixture; a nonzero value is
	# a determinism bug, not a tuning knob.
	queue = HitQueue.new(EVENT_BUDGET * SessionRules.MAX_PLAYERS, MAX_ENEMIES)
	director = SpawnDirector.new(base + _SEED_DIRECTOR)
	# The WHOLE campaign, plotted before the first frame: three arenas and the
	# corridors between them on one grid. Generated from the player's start,
	# because the spawn-safe margin is measured from wherever they actually are.
	_allocate_slots()
	_players = maxi(1, _session.descriptor.get("roster", []).size())
	director.rate_mult = float(_players)
	_flow = []
	for _s in SessionRules.MAX_PLAYERS:
		_flow.append(FlowField.new())
	_modules = ModuleTable.all()
	for mi in _modules.size():
		_module_index[_modules[mi].id] = mi
	var recipes := RecipeTable.all()
	for ri in recipes.size():
		_recipe_index[recipes[ri].fused.id] = ri
	_build_manifest()
	var tseed: int = base + _SEED_TERRAIN
	terrain = Terrain.new(ARENA_SIZE, SpawnDirector.CAMPAIGN_SUBNETS, tseed)
	# Every slot starts at the same origin, so the spawn-safe margin is measured
	# from where the party actually is.
	terrain.generate(tseed, player_pos[local_slot])

	_buf = PackedInt32Array(); _buf.resize(1024)
	_beam_hits = PackedInt32Array(); _beam_hits.resize(_buf.size())
	_beam_keys = PackedFloat32Array(); _beam_keys.resize(_buf.size())
	_counts = PackedInt32Array(); _counts.resize(4)
	_pos_arrays = [null, null, null, null]
	_skips = [null, null, null, null]
	var gids := SessionRules.MAX_PLAYERS * GID_STRIDE
	_fire_acc = PackedFloat32Array(); _fire_acc.resize(gids)
	_fire_cd = PackedFloat32Array(); _fire_cd.resize(gids)
	_ward_left = PackedFloat32Array(); _ward_left.resize(gids)
	_shield_left = PackedFloat32Array(); _shield_left.resize(gids)
	_proj_owner = PackedInt32Array(); _proj_owner.resize(MAX_PROJECTILES)
	_proj_pierce = PackedInt32Array(); _proj_pierce.resize(MAX_PROJECTILES)
	_proj_last = PackedInt32Array(); _proj_last.resize(MAX_PROJECTILES)
	_proj_dist_left = PackedFloat32Array(); _proj_dist_left.resize(MAX_PROJECTILES)
	_proj_target = PackedInt32Array(); _proj_target.resize(MAX_PROJECTILES)
	_proj_target_gen = PackedInt32Array(); _proj_target_gen.resize(MAX_PROJECTILES)
	_proj_reacquire = PackedFloat32Array(); _proj_reacquire.resize(MAX_PROJECTILES)
	_mine_left = PackedFloat32Array(); _mine_left.resize(MAX_PROJECTILES)
	_orbit_left = PackedFloat32Array(); _orbit_left.resize(MAX_PROJECTILES)
	_orbit_phase = PackedFloat32Array(); _orbit_phase.resize(MAX_PROJECTILES)
	_slow_left = PackedFloat32Array(); _slow_left.resize(MAX_ENEMIES)
	_ai_phase = PackedInt32Array(); _ai_phase.resize(MAX_ENEMIES)
	_ai_timer = PackedFloat32Array(); _ai_timer.resize(MAX_ENEMIES)
	_ai_aim = PackedVector2Array(); _ai_aim.resize(MAX_ENEMIES)
	_enemy_target = PackedInt32Array(); _enemy_target.resize(MAX_ENEMIES)
	_enemy_target.fill(-1)
	_live_pos = PackedVector2Array()
	_live_of = PackedInt32Array()
	_spawn_hp = PackedFloat32Array(); _spawn_hp.resize(MAX_ENEMIES)
	# Weight class per enemy TYPE, resolved once. Base integrity rather than
	# spawn HP: solidity is what a thing IS, and scaling by subnet would make
	# every daemon sound like a boss by subnet 03. The table falls naturally
	# into three groups — worm/daemon/tracer/probe at 6-16, the mid tier at
	# 34-70, mini-bosses and ICE at 170-700.
	_hit_weight = PackedByteArray()
	_hit_weight.resize(enemy_types.size())
	for wi in enemy_types.size():
		var hp0: float = enemy_types[wi].integrity
		_hit_weight[wi] = 0 if hp0 < 20.0 else (1 if hp0 < 80.0 else 2)
	_execute_immune_type = PackedByteArray()
	_execute_immune_type.resize(enemy_types.size())
	for mi_t in enemy_types.size():
		_execute_immune_type[mi_t] = 1 if _is_miniboss(mi_t) else 0
	_hit_flash = PackedFloat32Array(); _hit_flash.resize(MAX_ENEMIES)
	_arriving = PackedFloat32Array(); _arriving.resize(MAX_ENEMIES)
	_no_grid = PackedByteArray(); _no_grid.resize(MAX_ENEMIES)
	_submerged = PackedByteArray(); _submerged.resize(MAX_ENEMIES)
	_knock = PackedVector2Array(); _knock.resize(MAX_ENEMIES)
	_split_gen = PackedInt32Array(); _split_gen.resize(MAX_ENEMIES)
	_rewarded = PackedByteArray(); _rewarded.resize(MAX_ENEMIES)
	for _k in enemy_types.size():
		if enemy_types[_k].id == &"fork_bomb":
			_fork_bomb_index = _k
		elif enemy_types[_k].id == &"packet_filter":
			_packet_filter_index = _k
	_slow_factor = PackedFloat32Array(); _slow_factor.resize(MAX_ENEMIES)
	_worm_id = PackedInt32Array(); _worm_id.resize(MAX_ENEMIES)
	_worm_seg = PackedInt32Array(); _worm_seg.resize(MAX_ENEMIES)
	_order = PackedInt32Array(); _order.resize(MAX_ENEMIES)
	_band_count = PackedInt32Array(); _band_count.resize(DEPTH_BANDS + 1)
	_botnet_ratio = PackedFloat32Array(); _botnet_ratio.resize(MAX_BOTNET)
	_botnet_life = PackedFloat32Array(); _botnet_life.resize(MAX_BOTNET)

	_derive_roster()
	# A run exists only after START: from here the roster is frozen and a
	# HELLO can only be a return to a slot it already holds.
	_session.started = true
	_recompile()
	# One ring for the session, built AFTER the roster is LIVE: its masks follow
	# slot_state, and the opening delay ticks are primed with every present
	# slot's neutral record so nobody waits on input that cannot exist yet.
	lockstep = Lockstep.new(SessionRules.MAX_PLAYERS,
		int(_session.descriptor.get("delay", 0)))
	_session.lockstep = lockstep
	_sync_ring_roster()
	if lockstep.delay > 0:
		lockstep.prime(0, lockstep.delay - 1)

	_build_renderers()
	_camera = Camera2D.new()
	_camera.zoom = Vector2(1.15, 1.15)
	add_child(_camera)
	_camera.make_current()

	_build_environment()

	var pr := SaveGame.prefs()
	_shake_pref = float(pr.get("shake", 1.0))
	_numbers_pref = float(pr.get("damage_numbers", 1.0)) > 0.5

	# The node drains feel's event list. run.gd keeps no reference to it: the
	# simulation appends strings and forgets, which is what keeps the tick
	# reachable headless.
	var sfx := Node.new()
	sfx.set_script(load("res://scripts/audio/sfx.gd"))
	sfx.feel = feel
	add_child(sfx)

	# Generative music. It POLLS this node for threat; nothing here holds a
	# reference back, same direction as the Sfx node.
	var music := Node.new()
	music.set_script(load("res://scripts/audio/music.gd"))
	music.run = self
	add_child(music)

	var ui := CanvasLayer.new()
	ui.set_script(load("res://scripts/run/ui.gd"))
	add_child(ui)
	ui.bind(self)

	if external_drive:
		set_physics_process(false)

## Size every per-slot array for MAX_PLAYERS. Everything starts ABSENT and
## empty; _derive_roster fills the slots the descriptor names.
func _allocate_slots() -> void:
	var n := SessionRules.MAX_PLAYERS
	slot_state = PackedByteArray(); slot_state.resize(n)
	slot_state.fill(SlotState.ABSENT)
	player_pos = PackedVector2Array(); player_pos.resize(n)
	player_prev_pos = PackedVector2Array(); player_prev_pos.resize(n)
	player_render_pos = PackedVector2Array(); player_render_pos.resize(n)
	player_vel = PackedVector2Array(); player_vel.resize(n)
	player_facing = PackedVector2Array(); player_facing.resize(n)
	player_facing.fill(Vector2.RIGHT)
	player_health = PackedFloat32Array(); player_health.resize(n)
	player_iframe = PackedFloat32Array(); player_iframe.resize(n)
	player_shield = PackedFloat32Array(); player_shield.resize(n)
	_parked_health = PackedFloat32Array(); _parked_health.resize(n); _parked_health.fill(-1.0)
	pickup_radius = PackedFloat32Array(); pickup_radius.resize(n)
	kills = PackedInt32Array(); kills.resize(n)
	flips = PackedInt32Array(); flips.resize(n)
	_low_armed = PackedByteArray(); _low_armed.resize(n); _low_armed.fill(1)
	_zone_slow_player = PackedByteArray(); _zone_slow_player.resize(n)
	inputs = PackedVector2Array(); inputs.resize(n)
	_banked = []; _banked.resize(n)
	_sheet = []; _sheet.resize(n)
	_unlocked = []; _unlocked.resize(n)
	loadouts = []; loadouts.resize(n)
	resolved = []; resolved.resize(n * GID_STRIDE)
	_offer_seq = PackedInt32Array(); _offer_seq.resize(n)
	_offer_open = []; _offer_open.resize(n)
	_offer_queue = []; _offer_queue.resize(n)
	for s in n:
		_banked[s] = {&"salvage": 0, &"kills": 0, &"flips": 0}
		_sheet[s] = PlayerStats.BASE.duplicate()
		_unlocked[s] = []
		_offer_open[s] = {}
		_offer_queue[s] = []
	_rec_moves = PackedVector2Array(); _rec_moves.resize(n)
	_rec_cards = PackedInt32Array(); _rec_cards.resize(n)
	_rec_targets = PackedInt32Array(); _rec_targets.resize(n)
	_rec_offers = PackedInt32Array(); _rec_offers.resize(n)

## Bring every roster slot to LIVE with its starting build, sheet and unlock set
## derived from the counters the descriptor carries — the SAME derivation on
## every peer, so no process reads another player's save and no two peers can
## disagree about a starting build.
func _derive_roster() -> void:
	var table := ModuleTable.by_id()
	for row in _session.descriptor.get("roster", []):
		var s: int = int(row["slot"])
		var counters: Dictionary = row["counters"]
		slot_state[s] = SlotState.LIVE
		var lo := Loadout.new()
		lo.start(table[&"packet"], table[&"interval"])
		lo.mult = PlayerStats.mults(SaveGame.multipliers_from(counters))
		loadouts[s] = lo
		_sheet[s] = PlayerStats.sheet(SaveGame.player_sheet_from(counters))
		player_health[s] = _sheet[s][&"integrity"]
		pickup_radius[s] = _sheet[s][&"pickup_radius"]
		_unlocked[s] = SaveGame.unlocked_modules_from(counters)
	alive = _any_live()

func _any_live() -> bool:
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.LIVE:
			return true
	return false

func _eff_integrity(slot: int) -> float:
	return _sheet[slot][&"integrity"]

## Max over the OWNING slot's live wards, never a sum. A module id occupies one
## slot now, but a single exploit can still carry ward_* on two modules at once
## — a TRIGGER and a PAYLOAD both may — so summing would buy double magnitude at
## zero uptime cost, which is the build the design explicitly rejects.
## Compiler.MAX_FOLD_KEYS folds the same way for the same reason. Folds stop at
## the slot boundary: one player's ward never armours another.
func _ward_max(slot: int, key: StringName) -> float:
	var best := 0.0
	for gid in _slot_exploits(slot):
		if _ward_left[gid] > 0.0:
			best = maxf(best, float(resolved[gid].get(key)))
	return best

func _eff_armor(slot: int) -> float:
	return _sheet[slot][&"armor"] + _ward_max(slot, &"ward_armor")

func _eff_defense(slot: int) -> float:
	return _sheet[slot][&"defense"] + _ward_max(slot, &"ward_defense")

func _eff_clock_speed(slot: int) -> float:
	var v: float = _sheet[slot][&"clock_speed"] + _ward_max(slot, &"ward_clock_speed")
	# Applied last, so a slow zone cuts the total rather than the base and
	# cannot be out-scaled by buying clock_speed in the shop.
	if _zone_slow_player[slot] != 0:
		v *= Terrain.SLOW_FACTOR
	return v

func _mitigated(slot: int, amount: float) -> float:
	return PlayerStats.mitigate(amount, _eff_armor(slot), _eff_defense(slot))

## Compile one slot's loadout — or every manned slot when `slot` is -1 — into its
## stride of `resolved`. Entries beyond the loadout's exploits are nulled so a
## stale exploit can never outlive a card that replaced it.
func _recompile(slot: int = -1) -> void:
	for s in SessionRules.MAX_PLAYERS:
		if slot >= 0 and s != slot:
			continue
		var out: Array = []
		if loadouts[s] != null:
			out = loadouts[s].compile_all()
		for e in GID_STRIDE:
			resolved[_gid(s, e)] = out[e] if e < out.size() else null
	_rebuild_execute_table()
	emit_signal("stats_changed")

## Rebuilt with `resolved`, so the drain always reads the current build. Indexed
## by gid; an empty entry executes nothing.
func _rebuild_execute_table() -> void:
	_execute_by_exploit.resize(resolved.size())
	for i in resolved.size():
		var r: ResolvedExploit = resolved[i]
		_execute_by_exploit[i] = r.execute_below if r != null else 0.0

# ------------------------------------------------------- exploit ownership ---
#
# Every read that asks "which exploit owns this event, and whose build is it" —
# lifesteal, the flip's botnet, projectile origins, and trigger attribution —
# goes through these helpers, so the slot encoding lives in ONE place. The
# load-bearing rule they enforce is that a NEGATIVE owner id (the hit queue's -1
# unowned / -2 unset sentinels) decodes to no owner, never to slot zero: an
# unowned kill must credit nobody, not silently the first player. Integer
# division of -1 by the stride truncates to 0 in GDScript, which is exactly the
# trap, so the sign is checked BEFORE any division.

## The global id of exploit `exploit_index` on `slot`.
func _gid(slot: int, exploit_index: int) -> int:
	return slot * GID_STRIDE + exploit_index

## The ResolvedExploit an owner id refers to, or null for a negative sentinel,
## an out-of-range id, or an empty entry.
func _resolved(gid: int) -> ResolvedExploit:
	if gid < 0 or gid >= resolved.size():
		return null
	return resolved[gid]

## (slot, exploit_index) for an owner id, or (-1, -1) when the id is negative,
## out of range, or names an empty entry.
func _decode_exploit(gid: int) -> Vector2i:
	if gid < 0 or gid >= resolved.size() or resolved[gid] == null:
		return Vector2i(-1, -1)
	@warning_ignore("integer_division")
	return Vector2i(gid / GID_STRIDE, gid % GID_STRIDE)

## The slot that owns an id, or -1.
func _owner_slot(gid: int) -> int:
	return _decode_exploit(gid).x

## The gids of every compiled exploit on a slot, in exploit order.
func _slot_exploits(slot: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	if slot < 0 or slot >= SessionRules.MAX_PLAYERS:
		return out
	for e in GID_STRIDE:
		var gid := _gid(slot, e)
		if resolved[gid] != null:
			out.append(gid)
	return out

# ------------------------------------------------------- the LIVE census ---
#
# Every rule that used to say "the player" now says WHICH players, and these
# helpers are the whole vocabulary: the ascending LIVE list, the nearest LIVE
# slot to a point, the party's bounding box and centroid, and a deterministic
# cycling cursor for the spawn ring. Iteration is always ascending by slot and
# ties choose the lower slot, so every peer walks the same order and lands on
# the same answer. DEAD and ABSENT slots are skipped by every rule.

func _is_live(slot: int) -> bool:
	return slot >= 0 and slot < SessionRules.MAX_PLAYERS \
		and slot_state[slot] == SlotState.LIVE

func _live_slots() -> PackedInt32Array:
	var out := PackedInt32Array()
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.LIVE:
			out.append(s)
	return out

## The LIVE slot nearest a point, or -1 when nobody is LIVE. Strict less-than,
## so an exact tie goes to the lower slot.
func _nearest_live(point: Vector2) -> int:
	var best := -1
	var best_d := INF
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] != SlotState.LIVE:
			continue
		var d := player_pos[s].distance_squared_to(point)
		if d < best_d:
			best_d = d
			best = s
	return best

## The bounding box of every LIVE position. With nobody LIVE it collapses to the
## local slot's position so presentation still has a centre.
func _party_bounds() -> Rect2:
	var r := Rect2(player_pos[local_slot], Vector2.ZERO)
	var first := true
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] != SlotState.LIVE:
			continue
		if first:
			r = Rect2(player_pos[s], Vector2.ZERO)
			first = false
		else:
			r = r.expand(player_pos[s])
	return r

func _party_centroid() -> Vector2:
	var sum := Vector2.ZERO
	var n := 0
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.LIVE:
			sum += player_pos[s]
			n += 1
	return sum / float(n) if n > 0 else player_pos[local_slot]

## The next LIVE slot in a deterministic round-robin, for rules that spread work
## across the party — spawn rings, set-piece entrances, block placement. Each
## call advances the cursor; a DEAD or ABSENT slot is skipped, not counted.
var _cycle_cursor := 0
func _next_live_cycle() -> int:
	var live := _live_slots()
	if live.is_empty():
		return -1
	var pick: int = live[_cycle_cursor % live.size()]
	_cycle_cursor = (_cycle_cursor + 1) % live.size()
	return pick

## How many players the session was started with. Immutable: death and parking
## never lower it, so difficulty cannot be shed by a teammate leaving.
var _players := 1

# ---------------------------------------------------------------- the tick ---

func _physics_process(_dt: float) -> void:
	# Open the render layer's PAST before anything can move.
	#
	# Above the guard for the same reason _present is: a paused or ended run
	# still draws. If prev_pos kept the last MOVING tick's value, every entity
	# would swing between two positions for the length of the pause as the frame
	# fraction cycled 0..1. Snapshotting unconditionally makes prev == pos the
	# instant the simulation stops, so a paused screen is simply still.
	_snapshot_render_state()
	# Sampled once per TICK, not per frame, because a tick's worth of input is
	# the unit a client sends and a host consumes. Above the guard so the seam
	# has the same shape paused or not; the vector is simply unread while the
	# simulation is halted.
	_poll_local_input()

	# PRESENTATION, above the guard, every frame, unconditionally.
	#
	# Everything below the guard stops the moment the run ends or an overlay
	# opens. That is right for simulation and wrong for presentation: the death
	# shake would render zero frames, the effects would freeze mid-decay, and —
	# worst — the hitstop would never be released, because all three of its
	# triggers set one of these three flags on the frame they fire.
	# THE NETWORK, above the guard: receive whatever arrived (records land in
	# the ring, control messages in the session inbox), then, as host, send the
	# one relay bundle this tick owes every client. The simulation below never
	# sees any of this; it sees records.
	if _transport != null:
		_transport.poll()
		_drain_inbox()
		_reconnect_step()
		if _transport.is_host:
			_transport.flush_relay(lockstep.executed + lockstep.delay)

	_present(_dt)

	# A returnee holds everything until the host's snapshot lands: its state
	# is whatever it was when the link broke, and nothing may build on it.
	if _session.reconnecting:
		return
	_roster_step()

	# INPUT APPLICATION, above the world guard. The ring decides whether this
	# tick can execute at all: until every LIVE slot's record for it has
	# arrived, nothing below runs and the world holds. Once it can, exactly one
	# tick's records are taken and applied — movement into `inputs`, choices
	# into the offers — deadlines resolve, and a finished round opens the next.
	# All of that happens whether or not the world then steps: an open offer
	# holds the world, not the input stream, so a paused party still consumes
	# ticks and applies the choices that will unpause it.
	_sync_ring_roster()
	_recovery_step()
	_ending_step()
	if _session.terminated:
		return
	if not lockstep.ready(lockstep.executed) or _holding_for_snapshot():
		_stalled_ticks += 1
		return
	_stalled_ticks = 0
	tick = lockstep.executed
	lockstep.take(tick, _rec_moves, _rec_cards, _rec_targets, _rec_offers)
	_apply_records()
	_resolve_deadlines()
	_settle_offers()

	# The hitstop is part of the deterministic tick: it freezes the world for a
	# fixed number of ticks rather than slowing a process-global clock. Above the
	# world-step guard so the freeze is faithful even when a trigger also set a
	# guard flag on the same frame, and so presentation and input intake above
	# still run through it. A dead or paused run stays frozen by its own flag.
	#
	# `user_paused` gates the world in SOLO only. In a session it is a local
	# overlay: this peer's record carries zero movement while it is up, but
	# lockstep, the world and the hashes keep going, because one player's menu
	# cannot stop three others' game.
	var solo := _session.role == NetworkSession.Role.SOLO
	if hitstop_ticks > 0:
		hitstop_ticks -= 1
	elif not (paused or (user_paused and solo) or not alive or won or _session.ended):
		_step_world()
	_report_checksum()

## The periodic checksum: every CHECKSUM_INTERVAL consumed ticks, in a session,
## hash the executed state and report it — to the local ring, so this peer's
## own report takes part in desync_at, and to the wire. Solo reports nothing;
## there is nobody to disagree with.
func _report_checksum() -> void:
	if _transport == null or tick % SessionRules.CHECKSUM_INTERVAL != 0:
		return
	var h := _state_hash()
	lockstep.submit_checksum(local_slot, tick, h)
	_transport.send_checksum(tick, h)

## Control messages the transport validated, drained above the guard and
## dispatched here. Later tasks add ABSENT/PRESENT and the ending barrier.
func _drain_inbox() -> void:
	while not _session.inbox.is_empty():
		var msg: Dictionary = _session.inbox.pop_front()
		var body: Dictionary = msg["body"]
		var peer := int(msg["peer"])
		match int(msg["kind"]):
			Protocol.Message.RESYNC:
				if body.get("clears_end", false):
					_session.cancel_no_live_check()
				announce_resync(int(body["tick"]))
			Protocol.Message.HELLO:
				if _session.role == NetworkSession.Role.HOST:
					_pending_hello.append([body, peer])
			Protocol.Message.WELCOME:
				pass    # the descriptor is immutable; a returnee already holds it
			Protocol.Message.LEAVE:
				if _session.role == NetworkSession.Role.HOST and _transport != null \
						and _transport.slot_of_peer.has(peer):
					request_park(int(_transport.slot_of_peer[peer]))
					_transport.drop_peer(peer)
			Protocol.Message.ABSENT:
				if _session.role != NetworkSession.Role.HOST:
					_pending_absent[int(body["slot"])] = int(body["tick"])
			Protocol.Message.PRESENT:
				if _session.role != NetworkSession.Role.HOST:
					_pending_present[int(body["slot"])] = int(body["tick"])
			Protocol.Message.END_CANDIDATE:
				if _transport != null and _transport.slot_of_peer.has(peer):
					receive_end_candidate(int(_transport.slot_of_peer[peer]),
						int(body["tick"]), int(body["outcome"]), int(body["hash"]))
			Protocol.Message.END_CHECK:
				receive_end_check(int(body["tick"]))
			Protocol.Message.END:
				receive_end(int(body["tick"]), int(body["outcome"]))
			_:
				pass

## One fixed world step: the ordered tick, and only that. Everything about
## whether to run it was decided above.
func _step_world() -> void:
	# ONCE per tick, and before any step. It used to open _step5_fire, which
	# meant every event appended earlier in the tick — the mine fuse in
	# _step2_integrate, and the hazard and corruption zones in _step2b_zones —
	# was discarded before the drain ever saw it. Three shipped features dealt
	# zero damage. Nothing caught it: landmine ships LOCKED, so the autopiloted
	# run never equips one, and no suite asserted a zone or a fuse reduced
	# integrity. Below the pause guard, not above it: above, it would run on
	# every paused frame.
	queue.begin_tick()

	# The director steps in FIGHTING and nowhere else: a cleared subnet stops
	# producing, and the corridor never produces at all.
	# Every step ages by the FIXED tick, never the frame delta. The delta the
	# engine handed us drives presentation above; the world runs on one constant
	# so two peers stepping at different frame rates evolve identically.
	var sdt := SessionRules.TICK_DT
	if phase == Phase.FIGHTING:
		_step1_spawn(sdt)
	_step2_integrate(sdt)
	_step2c_gate()
	_step2d_collapse(sdt)
	_step2e_blocks(sdt)
	_step2b_zones(sdt)
	_step3_rebuild()
	# Only while something reads it. _approach_dir consults the field for bosses
	# and nothing else, so flooding 2401 cells through a wave of daemons buys
	# precisely nothing — and this is the whole of its cost, so gating it here
	# takes the flow field out of the tick entirely for most of a subnet.
	if boss_present():
		for s in SessionRules.MAX_PLAYERS:
			if slot_state[s] == SlotState.LIVE \
					and _flow[s].needs_rebuild(terrain, player_pos[s]):
				_flow[s].rebuild(terrain, player_pos[s])
	_step4_steer()
	_step5_fire(sdt)
	_step6_detect(sdt)
	_step6b_hostiles(sdt)
	_steps78_drain()
	_step9_recycle()
	_step9c_reapproach()
	_step9b_splits()

	# Sorted ONCE per tick, not once per drawn frame. _order is rebuilt wholesale
	# here and enemies.count cannot change between ticks, so the render pass in
	# _process reads a consistent order however many frames it draws from it.
	_depth_sort()

## The presentation half of the tick, run above the guard every frame — the
## world may be frozen by a hitstop, dead, or paused; presentation is not.
##
## Ages on the FRAME delta, clamped to MAX_PRESENT_DT. Nothing here reads a wall
## clock or an engine time scale any more: the hitstop is now a tick count above
## the guard, so during one the world simply does not step while these effects
## keep aging at their normal rate. The clamp keeps a first frame, a scene load,
## or an OS suspend from expiring every live effect in one huge step.
func _present(_dt: float) -> void:
	var udt := minf(_dt, MAX_PRESENT_DT)

	feel.step(udt)
	_age_fx(udt)
	_vignette = maxf(0.0, _vignette - udt * 2.5)
	var fi := 0
	while fi < _falling.size():
		_falling[fi][1] += udt
		if _falling[fi][1] >= FALL_LIFE:
			_falling.remove_at(fi)
		else:
			fi += 1

	# The shake preference multiplies the composed offset, outside Feel and
	# after the square — folded into trauma it would scale quadratically and a
	# legal shake of 2.0 would give 4x.
	# The camera and queue_redraw live in _process now, at display rate. What
	# stays here is the SHAKE MAGNITUDE, aged on the unscaled clock — the offset
	# it produces is composed into the camera per drawn frame.

## Everything the simulation does not own, at display rate rather than 60 Hz.
##
## The simulation ticks 60 times a second; a 144 Hz display draws 2.4 frames
## between two of those ticks. Reading `pos` directly would show the same
## position for all 2.4 of them and motion would step no matter how high the
## framerate went — which is what it did before this existed.
##
## Every entity is drawn BETWEEN its last two simulated positions. That is one
## tick (~16 ms) of latency, deliberately, and it buys motion that cannot judder:
## both endpoints have already happened, so there is never a guess to correct.
func _process(_dt: float) -> void:
	# Clamped, and this is the whole discipline. The fraction can overshoot 1.0
	# when a frame runs long, and drawing past the newest simulated position is
	# extrapolation — a guess that gets visibly retracted on the next tick.
	_alpha = clampf(Engine.get_physics_interpolation_fraction(), 0.0, 1.0)
	for s in SessionRules.MAX_PLAYERS:
		player_render_pos[s] = player_prev_pos[s].lerp(player_pos[s], _alpha)
	# The camera follows the VIEW: the local slot while it is LIVE, the
	# spectate target once it is not. The shake preference multiplies the
	# composed offset, outside Feel and after the square — folded into trauma
	# it would scale quadratically and a legal shake of 2.0 would give 4x.
	_refresh_view()
	_camera.global_position = to_iso(player_render_pos[view_slot]) \
		+ feel.shake_offset() * _shake_pref
	_update_renderers()
	queue_redraw()

## The ONLY place run.gd reads the device. test_input asserts that
## structurally: a second Input.* call anywhere in the simulation would be a
## second source of truth that a remote player has no way to feed.
##
## input_override wins when set. It is a WORLD direction — the hook every
## headless driver and the perf gate steer through — and it lands in the same
## slot by the same path a real device does, so the suites exercise the seam
## rather than a side door around it.
##
## Keyboard and stick are SCREEN-relative and are unprojected here, so W moves
## you up the screen rather than up the world axis (which under the projection
## points diagonally). The unprojection is a VIEW concern; it belongs on this
## side of the seam, not in the tick.
func _poll_local_input() -> void:
	if _session.reconnecting:
		return
	var move := Vector2.ZERO
	if input_override != null:
		move = (input_override as Vector2).normalized()
	else:
		# One call reads both axes, so an analog stick comes along for free —
		# the InputMap carries the keyboard and the gamepad bindings together
		# and neither can drift from the other.
		var screen := Input.get_vector("move_left", "move_right",
			"move_up", "move_down")
		if screen.length_squared() > 0.0:
			# Uniform SCREEN speed, not uniform world speed.
			#
			# Normalising the WORLD direction keeps world speed constant, which
			# makes on-screen speed inherit the 2:1 squash — left/right moves
			# twice as fast as up/down, which is what makes the controls feel
			# lopsided. Because to_iso(from_iso(d)) == d exactly, feeding the
			# unprojected direction through WITHOUT renormalising makes the
			# on-screen velocity exactly clock_speed in every direction.
			#
			# The trade is that world speed now varies with heading (fastest
			# along the screen vertical, where the projection compresses most).
			# That is the right way round for a game where every dodge is
			# judged on screen.
			move = from_iso(screen.normalized())
	# A session pause is a local overlay: the record it sends is neutral. So is
	# the record of a DEAD slot, and of a world held in an unconfirmed terminal
	# state — the controller stays PRESENT and keeps the host's ring fed, but a
	# dead player's choice can never land.
	if _session.role != NetworkSession.Role.SOLO \
			and (user_paused or slot_state[local_slot] != SlotState.LIVE or not alive or won):
		move = Vector2.ZERO
		_local_choice = Vector3i(-1, -1, -1)
	# The sampled intent is visible immediately for the local slot; the value
	# the simulation actually applies is whatever the ring hands back for the
	# tick it executes, which at delay zero is this same record.
	inputs[local_slot] = move
	# Submit the FULL record — movement plus any staged choice — for the tick
	# this peer is running ahead. The staged choice is consumed only when the
	# submit lands; a duplicate for a tick already recorded leaves it for the
	# next tick rather than losing it.
	var c := _local_choice
	var t := lockstep.executed + lockstep.delay
	if lockstep.submit(local_slot, t, move, c.x, c.y, c.z):
		_local_choice = Vector3i(-1, -1, -1)
		# The same immutable record goes on the wire — to the host, or into
		# the host's own relay staging — exactly once, the tick it was made.
		if _transport != null:
			_transport.send_input(t, move, c.x, c.y, c.z)

## Keep the ring's roster masks in step with slot_state, so a slot marked DEAD
## or ABSENT by the simulation stops being waited on the same tick.
func _sync_ring_roster() -> void:
	for s in SessionRules.MAX_PLAYERS:
		match slot_state[s]:
			SlotState.LIVE:
				lockstep.mark_live(s)
			SlotState.DEAD:
				lockstep.mark_present(s)
				lockstep.mark_dead(s)
			_:
				lockstep.mark_absent(s)

## Apply the tick's records: sanitised movement into `inputs`, and each slot's
## choice against its open offer. The stored record is never altered — a
## hostile movement is treated as neutral HERE, at application, so every peer
## applies the same value from the same immutable bytes.
func _apply_records() -> void:
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] != SlotState.LIVE:
			inputs[s] = Vector2.ZERO
			continue
		inputs[s] = _sanitise_move(_rec_moves[s])
		if _rec_cards[s] != -1:
			_apply_choice(s, _rec_cards[s], _rec_targets[s], _rec_offers[s])

## A movement with a non-finite component, or one past MOVE_COMPONENT_MAX on
## either axis, is Vector2.ZERO; anything else is preserved unchanged. clampf is
## not a finiteness check, so the components are tested explicitly.
static func _sanitise_move(m: Vector2) -> Vector2:
	if not is_finite(m.x) or not is_finite(m.y):
		return Vector2.ZERO
	var cap := SessionRules.MOVE_COMPONENT_MAX
	if absf(m.x) > cap or absf(m.y) > cap:
		return Vector2.ZERO
	return m

## Copy every population's `pos` into its `prev_pos`. One memcpy each, not a
## loop over ~2700 entities — see Population.snapshot. The four player slots are
## copied by element: packed arrays are passed by reference in Godot 4, so a
## plain assignment would alias the two and the render past would vanish.
func _snapshot_render_state() -> void:
	enemies.snapshot()
	projectiles.snapshot()
	shards.snapshot()
	botnet.snapshot()
	hostiles.snapshot()
	for s in SessionRules.MAX_PLAYERS:
		player_prev_pos[s] = player_pos[s]

## Where to DRAW entity `i` of population `p` this frame.
func _rp(p: Population, i: int) -> Vector2:
	return p.prev_pos[i].lerp(p.pos[i], _alpha)

## Owe the tick a fixed number of world-frozen ticks. Rare events only: at the
## enemy cap a per-kill hitstop is a permanent stutter, not emphasis. Overlapping
## hitstops take the MAX rather than summing, so a death during a miniboss beat
## does not stack into a long freeze. No engine clock — the tick above the guard
## spends these ticks, and every peer spends the same ones on the same events.
func _hitstop() -> void:
	hitstop_ticks = maxi(hitstop_ticks, SessionRules.HITSTOP_TICKS)

## Open ground inside the CURRENT arena.
##
## The spawn ring is centred on the player and knows nothing about the arena, so
## near an edge it placed enemies outside it — invisible against the void in the
## isometric view, and unreachable in either. That matters more now the map is a
## whole campaign: unclamped, a player who has just walked in through a corridor
## gets half their wave spawned in the subnet behind them.
func _spawn_at(p: Vector2) -> Vector2:
	var a: Rect2 = terrain.arena().grow(-24.0)
	return terrain.nearest_open(p.clamp(a.position, a.end))

func _step1_spawn(dt: float) -> void:
	# The spawn ring cycles through the LIVE party, so a spread party is pressed
	# from every side rather than only around slot zero.
	var ring_slot := _next_live_cycle()
	if ring_slot < 0:
		return
	for s in director.step(dt, player_pos[ring_slot], SPAWN_RING):
		var ti: int = s[0]
		s[1] = _spawn_at(s[1])
		if ti == WORM_TYPE:
			if _spawn_worm(s[1]):
				director.spawned += 1
			else:
				director.dropped += 1
			continue
		var t = enemy_types[ti]
		var hp: float = t.integrity * _hp_mult()
		var idx := enemies.spawn(s[1], Vector2.ZERO,
			hp, ENEMY_RADIUS, ti)
		if idx < 0:
			director.dropped += 1
		else:
			_spawn_enemy_state(idx, hp, t.behaviour)
			director.spawned += 1
	for mb in director.due_minibosses(dt):
		_spawn_miniboss(mb)
	if director.should_spawn_boss():
		director.boss_spawned = true
		# The network purges its own processes to make room for ICE. Mechanically
		# this is what makes the boss the fight rather than one target buried in
		# a few hundred leftovers that spawning already stopped replacing.
		# Despawn immediately rather than marking DEAD: recycle is step 9, so a
		# marked-but-not-freed pool is still full here and the boss spawn
		# silently returns -1 while boss_spawned is set, so it never retries.
		while enemies.count > 0:
			enemies.despawn(enemies.count - 1)
		_worm_trail.clear()
		_worm_cursor.clear()
		var b = enemy_types[EnemyTable.ICE]
		var a := _rng.randf() * TAU
		var bi := enemies.spawn(
			_spawn_at(player_pos[ring_slot] + Vector2(cos(a), sin(a)) * 420.0),
			Vector2.ZERO, b.integrity * _hp_mult(), 48.0, EnemyTable.ICE)
		assert(bi >= 0, "boss failed to spawn into a freshly emptied pool")
		# The arena was just emptied for mechanical reasons; the side effect is
		# a set-piece beat — empty ground, a held second, then the thing walks
		# in. ICE arrives into that rather than into a swarm.
		_arriving[bi] = ARRIVAL_TOTAL
		feel.emit("ice_charge")
		emit_signal("stats_changed")

## Longer worms later in the run: two segments at the start, up to six by the
## time ICE arrives.
func _worm_length() -> int:
	return mini(WORM_MAX_SEGMENTS,
		WORM_BASE_SEGMENTS + int(director.elapsed / WORM_GROWTH_SECONDS))

## Mini-bosses arrive on the spawn ring like anything else, but announced: an
## arrival the player does not notice is not a set-piece.
## How loud the arena is, 0..1. Polled by the music node, which is the only
## consumer — the simulation neither knows nor cares that it exists.
##
## Deliberately not just "how many enemies": a cleared subnet with a hundred
## stragglers is calm, and a boss alone is not. What this reports is how much
## trouble the player is in.
func threat() -> float:
	if not alive or won:
		return 0.0
	if phase == Phase.CLEARED:
		# The walk to the gate. Nothing is spawning; the arrangement should
		# breathe out.
		return 0.08
	var pressure: float = clampf(float(enemies.count) / 130.0, 0.0, 1.0)
	var hurt: float = 1.0 - clampf(player_health[local_slot]
		/ maxf(_eff_integrity(local_slot), 1.0), 0.0, 1.0)
	var t: float = maxf(pressure, hurt * 0.85)
	if boss_present():
		t = maxf(t, 0.78)
	return clampf(t, 0.0, 1.0)

## True while ICE or a mini-boss is alive AND has finished arriving. Gated on
## arrival so the pedal lands with the boss rather than under its telegraph.
func boss_present() -> bool:
	for i in enemies.count:
		if _arriving[i] > 0.0:
			continue
		var ti := enemies.type_index[i]
		if ti == EnemyTable.ICE or _is_miniboss(ti):
			return true
	return false

## Whether an enemy is still materialising.
func is_arriving(i: int) -> bool:
	return i >= 0 and i < _arriving.size() and _arriving[i] > 0.0

func _is_miniboss(type_index: int) -> bool:
	return enemy_types[type_index].id in SpawnDirector.MINIBOSS_IDS

## Splits land AFTER step 9, never inside the drain — the same once-per-tick
## discipline the subnet advance keeps.
func _step9b_splits() -> void:
	if _pending_splits.is_empty():
		return
	for entry in _pending_splits:
		for k in 2:
			# Shared simulation randomness, so it draws from _rng, not any one
			# player's card stream — a split is the world's event, not a choice.
			var at: Vector2 = entry[0] + Vector2(
				_rng.randf_range(-34.0, 34.0),
				_rng.randf_range(-34.0, 34.0))
			var hp: float = entry[2]
			var idx := enemies.spawn(_spawn_at(at), Vector2.ZERO, hp,
				20.0, _fork_bomb_index)
			if idx < 0:
				continue        # pool full: drop the child rather than overflow
			_spawn_enemy_state(idx, hp, EnemyTable.Behaviour.CHARGER)
			_split_gen[idx] = entry[1]
			# Children are not a second payday.
			_rewarded[idx] = 1
	_pending_splits.clear()

## null_ptr leaves a damaging afterimage each time it drops out of the world, so
## a long fight progressively denies you ground.
func _leave_afterimage(at: Vector2) -> void:
	terrain.add_temp_zone(at, AFTERIMAGE_RADIUS, Terrain.Kind.HAZARD,
		AFTERIMAGE_SECONDS)

func _spawn_miniboss(type_index: int) -> void:
	var t = enemy_types[type_index]
	# Shared simulation randomness: the spawn angle is the world's, not a player's.
	var a := _rng.randf() * TAU
	var ring_slot := maxi(_next_live_cycle(), 0)
	var at := _spawn_at(player_pos[ring_slot] + Vector2(cos(a), sin(a)) * 620.0)
	var hp: float = t.integrity * _hp_mult()
	var idx := enemies.spawn(at, Vector2.ZERO, hp, 26.0, type_index)
	if idx < 0:
		return
	_spawn_enemy_state(idx, hp, t.behaviour)
	_arriving[idx] = ARRIVAL_TOTAL
	feel.emit("miniboss_charge")
	director.spawned += 1
	emit_signal("stats_changed")

func _spawn_worm(at: Vector2) -> bool:
	var t = enemy_types[WORM_TYPE]
	var n := _worm_length()
	if enemies.count + n > MAX_ENEMIES:
		return false
	var id := _next_worm_id
	_next_worm_id += 1
	var trail := PackedVector2Array()
	trail.resize(WORM_TRAIL_LEN)
	trail.fill(at)
	_worm_trail[id] = trail
	_worm_cursor[id] = 0
	for k in n:
		var whp: float = t.integrity * _hp_mult()
		var idx := enemies.spawn(_spawn_at(at), Vector2.ZERO,
			whp, ENEMY_RADIUS, WORM_TYPE)
		if idx < 0:
			return k > 0
		# After _spawn_enemy_state, which zeroes _worm_id.
		_spawn_enemy_state(idx, whp)
		_worm_id[idx] = id
		_worm_seg[idx] = k
	return true

func _worm_sample(id: int, steps_back: int) -> Vector2:
	var trail: PackedVector2Array = _worm_trail[id]
	var c: int = _worm_cursor[id]
	return trail[(c - steps_back + WORM_TRAIL_LEN * 2) % WORM_TRAIL_LEN]

func _step2_integrate(dt: float) -> void:
	# The simulation reads its slot and nothing else. Where the direction came
	# from — keyboard, stick, a headless driver, a packet — was settled in
	# _poll_local_input, above the guard, and is none of the tick's business.
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] != SlotState.LIVE:
			continue
		var world_dir: Vector2 = inputs[s]
		if world_dir.length_squared() > 0.0:
			player_facing[s] = world_dir.normalized()
		var pos_before := player_pos[s]
		var p := pos_before
		if world_dir.length_squared() > 0.0:
			# The LEASH, tested on the PROPOSED position before the terrain slide
			# and clamped on the excess axis only, toward the rest of the party:
			# a soft wall a little over three screens from the farthest teammate,
			# so the party can never span more than the grid window. Solo has no
			# teammate to measure against and is unaffected.
			var proposed := pos_before + world_dir * _eff_clock_speed(s) * dt
			proposed = _leash(s, proposed)
			p = terrain.slide(pos_before, proposed - pos_before)
		# Clamped to the GRID, not the arena: the corridor lies legitimately
		# outside the arena rect, and the margin's solid cells are what actually
		# stop you.
		p = p.clamp(terrain.origin + Vector2(40, 40),
			terrain.origin + terrain.size - Vector2(40, 40))
		player_pos[s] = p
		player_vel[s] = (p - pos_before) / maxf(dt, 0.0001)
		if player_iframe[s] > 0.0:
			player_iframe[s] -= dt
	# The players have moved for this tick; pack the LIVE positions once for
	# every per-entity scan that follows.
	_refresh_live_cache()
	for wi in _ward_left.size():
		if _ward_left[wi] > 0.0 and _is_live(_owner_slot(wi)):
			_ward_left[wi] -= dt
	for si in _shield_left.size():
		if _shield_left[si] > 0.0 and _is_live(_owner_slot(si)):
			_shield_left[si] -= dt

	# Heads and ordinary enemies move first so the trail is current before the
	# segments sample it this same tick.
	for i in enemies.count:
		if _worm_id[i] != 0 and _worm_seg[i] != 0:
			continue
		# The arrival timer runs on the SIMULATION clock, not the presentation
		# one: a boss must not finish materialising behind a card screen.
		if _arriving[i] > 0.0:
			var was: float = _arriving[i]
			_arriving[i] = maxf(0.0, _arriving[i] - dt)
			# The crossing, not the value: one flash per arrival rather than one
			# per frame of the pop.
			if was > ARRIVAL_POP and _arriving[i] <= ARRIVAL_POP:
				var ice := enemies.type_index[i] == EnemyTable.ICE
				feel.add_trauma(0.8 if ice else 0.5)
				feel.emit("ice_arrive" if ice else "miniboss_arrive")
				_fx.append([FxKind.RIPPLE, enemies.pos[i], Vector2.RIGHT, 40.0, FX_LIFE * 5.0, Color(2.4, 2.2, 2.0)])
			# THE pass that matters. _behave dispatches to _charge / _ranged /
			# _pulse / _support / _ambush / _flank, so without this gate an
			# arriving boss chases at full speed (ICE is CHASE), _ranged spawns
			# hostile shots through _fire_hostile, and _pulse calls
			# _damage_player directly on a line-of-sight check with no grid
			# involved at all. Skipping _step4_steer instead — as an earlier
			# draft of the spec proposed — would have stopped none of that.
			enemies.vel[i] = Vector2.ZERO
			continue
		var t = enemy_types[enemies.type_index[i]]
		enemies.vel[i] = _behave(i, t, dt) + enemies.force[i] + _knock[i]
		_knock[i] = _knock[i].lerp(Vector2.ZERO, minf(KNOCK_DECAY * dt, 1.0))
		# Worms phase through terrain, HEADS INCLUDED. Segments are sampled from
		# the head's trail rather than integrated, so colliding the head alone
		# would stretch the body through the wall the head is stuck against.
		if _worm_id[i] != 0:
			enemies.pos[i] += enemies.vel[i] * dt
		else:
			# Hard rejection, not a hope. Avoidance is steering and can fail on a
			# concave wall; this is what makes "no enemy ends a tick inside rock"
			# true for every enemy on every tick regardless of how steering did.
			enemies.pos[i] = terrain.slide(enemies.pos[i], enemies.vel[i] * dt)
		if _worm_id[i] != 0:
			var id := _worm_id[i]
			var c: int = (_worm_cursor[id] + 1) % WORM_TRAIL_LEN
			_worm_cursor[id] = c
			var trail: PackedVector2Array = _worm_trail[id]
			trail[c] = enemies.pos[i]
			_worm_trail[id] = trail
	for i in enemies.count:
		var wid := _worm_id[i]
		if wid == 0 or _worm_seg[i] == 0:
			continue
		if not _worm_trail.has(wid):
			continue
		var prev := enemies.pos[i]
		enemies.pos[i] = _worm_sample(wid, _worm_seg[i] * WORM_SEG_STEPS)
		enemies.vel[i] = (enemies.pos[i] - prev) / maxf(dt, 0.0001)
	for i in projectiles.count:
		# Orbiters have a PARAMETRIC position rather than a velocity, so they
		# ride the player instead of flying away from where they were fired.
		if _orbit_left[i] > 0.0:
			_orbit_left[i] -= dt
			if _orbit_left[i] <= 0.0:
				projectiles.state[i] = Population.DEAD
				continue
			_orbit_phase[i] += ORBIT_RATE * dt
			# Re-anchored on the OWNING slot: an orbiter rides the player who
			# fired it, never whoever happens to be slot zero.
			var anchor := maxi(_owner_slot(_proj_owner[i]), 0)
			projectiles.pos[i] = player_pos[anchor] + Vector2(cos(_orbit_phase[i]),
				sin(_orbit_phase[i])) * 92.0
			continue
		# Mines sit still until something is close enough, then go off.
		if _mine_left[i] > 0.0:
			_mine_left[i] -= dt
			if _mine_left[i] <= 0.0:
				projectiles.state[i] = Population.DEAD
				continue
			if grid.query_radius_into(projectiles.pos[i], MINE_TRIGGER, _buf,
					Grid.M_ENEMY) > 0:
				# Owner into a local and guarded FIRST: the subscript is
				# evaluated before the call, and `resolved` shrinks whenever a
				# card recompiles, so an in-flight mine can outlive its index.
				var mo := _resolved(_proj_owner[i])
				_detonate(i, mo.radius if mo != null else 0.0)
			continue
		var pe := _proj_owner[i]
		var pr := _resolved(pe)
		if pr != null and pr.homing > 0.0:
			var tj := _proj_target[i]
			_proj_reacquire[i] = maxf(0.0, _proj_reacquire[i] - dt)
			# Re-acquire when the bound target has died or its slot recycled.
			if _proj_reacquire[i] <= 0.0 and (tj < 0 or tj >= enemies.count \
					or enemies.generation[tj] != _proj_target_gen[i] \
					or enemies.state[tj] != Population.ALIVE):
				tj = _pick_target(HOMING_REACQUIRE, pr.targeting,
					projectiles.pos[i])
				_proj_target[i] = tj
				_proj_target_gen[i] = enemies.generation[tj] if tj >= 0 else -1
				# A miss backs off. Without it a homing shot over cleared ground
				# re-runs the grid query every tick, for every such projectile —
				# the exact per-tick cost the binding exists to avoid.
				if tj < 0:
					_proj_reacquire[i] = HOMING_RETRY
			if tj >= 0:
				var want := (enemies.pos[tj] - projectiles.pos[i]).angle()
				var have := projectiles.vel[i].angle()
				var turn := clampf(wrapf(want - have, -PI, PI),
					-pr.homing * dt, pr.homing * dt)
				projectiles.vel[i] = projectiles.vel[i].rotated(turn)
		projectiles.pos[i] += projectiles.vel[i] * dt
		# Population stores no scalar speed, so the step is the velocity's
		# length: one sqrt per live projectile per tick, bounded by
		# MAX_PROJECTILES. This is the first thing that can mark a projectile
		# dead in step 2, which is why _step6_detect needs its state guard.
		_proj_dist_left[i] -= projectiles.vel[i].length() * dt
		if _proj_dist_left[i] <= 0.0:
			_expire_projectile(i)
		# Terrain stops shots. This is what makes a wall cover rather than
		# decoration, and it is the same O(1) lookup the player's movement uses.
		elif terrain.is_solid(projectiles.pos[i]):
			_expire_projectile(i)
	for i in botnet.count:
		_botnet_life[i] -= dt
	# _age_fx is NOT called here. It ages presentation, so it belongs above the
	# tick guard with the rest of it — called from _present() on the unscaled
	# clock. Aging it here froze every effect the instant the run ended.
	# The magnet, by GRID QUERY from each LIVE slot rather than a pass over every
	# shard: at the shard cap a per-shard scan was a measurable slice of the
	# tick, and only the shards inside a player's reach can move. The grid is
	# last tick's — rebuilt in step 3 — which is exact for shards (only this
	# magnet moves them) and one tick late for a shard dropped this tick, which
	# nobody can see. A shard inside two players' reach still goes to the
	# NEAREST, as it always did.
	var nlive := _live_pos.size()
	if nlive > 0 and shards.count > 0:
		for k in nlive:
			var ms: int = _live_of[k]
			var sp := _live_pos[k]
			var reach := pickup_radius[ms] * 2.2
			var n := grid.query_radius_into(sp, reach, _buf, Grid.M_SHARD)
			for j in mini(n, _buf.size()):
				var si := Grid.index_of(_buf[j])
				if si >= shards.count:
					continue
				var spos := shards.pos[si]
				var mine := true
				var md := spos.distance_squared_to(sp)
				for k2 in nlive:
					if k2 != k and spos.distance_squared_to(_live_pos[k2]) < md:
						mine = false
						break
				if not mine:
					continue
				var d := sp - spos
				if d.length() < reach:
					shards.pos[si] += d.normalized() * 300.0 * dt

## Pack the LIVE slots' positions and ids for this tick's per-entity scans.
func _refresh_live_cache() -> void:
	_live_pos.clear()
	_live_of.clear()
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.LIVE:
			_live_pos.append(player_pos[s])
			_live_of.append(s)

## Hold a proposed position inside LEASH of every other LIVE slot, per axis.
## Only the axis that overshoots is clamped, and only by the excess, so a
## teammate walking away is stopped rather than yanked. Returns the proposal
## unchanged when this is the only LIVE slot.
func _leash(slot: int, proposed: Vector2) -> Vector2:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	var others := 0
	for o in SessionRules.MAX_PLAYERS:
		if o == slot or slot_state[o] != SlotState.LIVE:
			continue
		lo = lo.min(player_pos[o])
		hi = hi.max(player_pos[o])
		others += 1
	if others == 0:
		return proposed
	var leash := float(SessionRules.LEASH)
	var out := proposed
	out.x = clampf(out.x, hi.x - leash, lo.x + leash)
	out.y = clampf(out.y, hi.y - leash, lo.y + leash)
	return out

func _age_fx(dt: float) -> void:
	for f in enemies.count:
		if _hit_flash[f] > 0.0:
			_hit_flash[f] = maxf(0.0, _hit_flash[f] - dt * HIT_FLASH_DECAY)
	var i := 0
	while i < _fx.size():
		_fx[i][4] -= dt
		if _fx[i][4] <= 0.0:
			_fx.remove_at(i)
		else:
			i += 1

func _step3_rebuild() -> void:
	_pos_arrays[Grid.Pop.ENEMY] = enemies.pos
	_pos_arrays[Grid.Pop.PROJECTILE] = projectiles.pos
	_pos_arrays[Grid.Pop.BOTNET] = botnet.pos
	_pos_arrays[Grid.Pop.SHARD] = shards.pos
	_counts[Grid.Pop.ENEMY] = enemies.count
	_counts[Grid.Pop.PROJECTILE] = projectiles.count
	_counts[Grid.Pop.BOTNET] = botnet.count
	_counts[Grid.Pop.SHARD] = shards.count
	# Rebuilt whole, every tick.
	for i in enemies.count:
		_no_grid[i] = 1 if (_submerged[i] != 0 or _arriving[i] > 0.0) else 0
	_skips[Grid.Pop.ENEMY] = _no_grid
	grid.set_window(_party_window())
	grid.rebuild(_pos_arrays, _counts, _skips)

## The world rectangle the spatial grid covers this tick: the bounding box of
## every LIVE slot grown by half a GRID_WINDOW on every side, never smaller than
## a GRID_WINDOW square, held inside the terrain grid, and cell-snapped outward
## — origin floored, span ceiled to whole cells. A lone player yields exactly the
## old follow-the-player 3200 square; a spread party yields up to the 7200 cap
## the leash guarantees.
func _party_window() -> Rect2:
	var half := GRID_WINDOW * 0.5
	var b := _party_bounds().grow(half)
	var origin := (b.position / CELL).floor() * CELL
	var span := (b.size / CELL).ceil() * CELL
	span = span.max(Vector2(GRID_WINDOW, GRID_WINDOW))
	span = span.min(Vector2(SessionRules.MAX_WINDOW, SessionRules.MAX_WINDOW))
	# Hold the window inside the terrain grid. Terrain bounds are cell-aligned and
	# the span is a whole number of cells, so the clamp keeps the origin aligned;
	# with the terrain far larger than the window it is a no-op away from the very
	# edges.
	var lo: Vector2 = terrain.origin
	var hi: Vector2 = terrain.origin + terrain.size - span
	if hi.x >= lo.x:
		origin.x = clampf(origin.x, lo.x, hi.x)
	if hi.y >= lo.y:
		origin.y = clampf(origin.y, lo.y, hi.y)
	return Rect2(origin, span)

## Steering is time-sliced across STEER_SLICES ticks: each tick recomputes one
## slice and every other enemy keeps the force it was last given. At 60 Hz a
## force is at most 2 ticks (33 ms) stale, which is invisible on a separation
## nudge, and it was the largest single item in the tick by a wide margin.
func _step4_steer() -> void:
	_steer_phase = (_steer_phase + 1) % STEER_SLICES
	var i := _steer_phase
	while i < enemies.count:
		# Garnish rather than the meal — the integrate gate already stops an
		# arriving boss moving — but it keeps neighbours from shoving a ghost.
		if _arriving[i] > 0.0:
			i += STEER_SLICES
			continue
		if _worm_id[i] != 0 and _worm_seg[i] != 0:
			i += STEER_SLICES
			continue
		var here := enemies.pos[i]
		# The target _behave chose this tick, so the range gate and the avoidance
		# direction below agree with the steer target.
		var ts := _enemy_target[i]
		if ts < 0 or here.distance_squared_to(player_pos[ts]) > STEER_RANGE_SQ:
			enemies.force[i] = Vector2.ZERO
			i += STEER_SLICES
			continue
		var n := grid.query_radius_into(here, SEPARATION_RADIUS, _buf, Grid.M_ENEMY)
		var push := Vector2.ZERO
		for k in mini(n, _buf.size()):
			var j := Grid.index_of(_buf[k])
			if j == i:
				continue
			var d := here - enemies.pos[j]
			var dl := d.length()
			if dl > 0.001:
				push += d / dl * (SEPARATION_RADIUS - dl)
		enemies.force[i] = push * 2.2 + terrain.avoid(here, player_pos[ts] - here)
		i += STEER_SLICES

## Event triggers respond only when off cooldown. Returns false when the
## exploit is still recovering, so callers can skip the emit.
## Fire every exploit whose trigger matches. The event triggers all share this;
## each hook only has to name its kind.
func _fire_trigger(kind: int) -> void:
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if r != null and not r.inert and r.trigger_kind == kind:
			_try_event_fire(ei, r)

## Bounded for the same reason FIRE_BUDGET bounds the interval path: a stat that
## multiplies emissions is a stat that can be stacked.
const BURST_MAX := 12

func _try_event_fire(ei: int, r: ResolvedExploit) -> bool:
	if _fire_cd[ei] > 0.0:
		return false
	_fire_cd[ei] = r.cooldown
	# Rarity is paid in emissions: a trigger that fires once a level should
	# produce a moment, while one that fires on every hit should not.
	for k in clampi(maxi(int(r.burst), 1), 1, BURST_MAX):
		_emit_vector(ei, r)
	return true

func _step5_fire(dt: float) -> void:
	# Only a LIVE slot's build fires or recovers. A DEAD or ABSENT slot's
	# cooldowns and accumulators are FROZEN — a returning player resumes exactly
	# where they left off, and a parked build cannot keep shooting.
	for ei in _fire_cd.size():
		if _fire_cd[ei] > 0.0 and _is_live(_owner_slot(ei)):
			_fire_cd[ei] -= dt
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if r == null or r.inert or not _is_live(_owner_slot(ei)):
			continue
		if r.trigger_kind != Module.TriggerKind.INTERVAL:
			continue
		_fire_acc[ei] += dt
		var fires := 0
		# Bank the remainder rather than zeroing: zeroing quantises the period to
		# tick multiples, so a cooldown of 0.051 fires at 0.0667 — a 24% DPS loss
		# that makes +cooling purchases do nothing until they cross a boundary.
		while _fire_acc[ei] >= r.cooldown and fires < FIRE_BUDGET:
			_fire_acc[ei] -= r.cooldown
			_emit_vector(ei, r)
			fires += 1
		_fire_acc[ei] = minf(_fire_acc[ei], r.cooldown * FIRE_BUDGET)

## Emit one exploit's vector from its OWNING slot's position. `ei` is a gid; the
## owner is decoded once here and every origin, telegraph, target scan and
## shield below reads that slot — never whoever is slot zero.
func _emit_vector(ei: int, r: ResolvedExploit) -> void:
	var owner := _owner_slot(ei)
	if owner < 0:
		return
	var at := player_pos[owner]
	feel.emit(Synth.fire_id(r.vector_kind))
	_trigger_fires[ei] = _trigger_fires.get(ei, 0) + 1
	# Before the match, deliberately. CHAIN returns early when it has no
	# target, and a defensive build on it must still ward — it has already spent
	# its cooldown by the time it reaches here, because _try_event_fire sets
	# _fire_cd before calling this. (BEAM and CONE no longer return early: they
	# fire along facing whether or not anything is there.)
	if r.ward_duration > 0.0:
		_ward_left[ei] = r.ward_duration
	# A shielding exploit grants its pool on fire, capped rather than stacked
	# (shield folds by MAX). A pool with a rearm grants only when the rearm has
	# elapsed: it keeps a payload's shield off the host vector's cadence.
	if r.shield > 0.0 and (r.shield_rearm <= 0.0 or _shield_left[ei] <= 0.0):
		player_shield[owner] = maxf(player_shield[owner], r.shield)
		if r.shield_rearm > 0.0:
			_shield_left[ei] = r.shield_rearm
	match r.vector_kind:
		Module.VectorKind.BROADCAST:
			_fx.append([FxKind.RIPPLE, at, Vector2.RIGHT, r.radius, FX_LIFE, Color(0.5, 1.7, 1.1)])
			var n := grid.query_radius_into(at, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(n, _buf.size()):
				_hit(ei, r, Grid.index_of(_buf[k]))
		Module.VectorKind.BEAM:
			# A capsule along the owner's facing: length radius, half-width
			# BEAM_HALF_WIDTH. Fires whether or not anything is in it.
			var dir: Vector2 = player_facing[owner]
			var mid := at + dir * r.radius * 0.5
			_fx.append([FxKind.BEAM, at, dir, r.radius, FX_LIFE, Color(2.2, 1.4, 2.6)])
			var n2 := grid.query_radius_into(mid, r.radius * 0.5 + BEAM_HALF_WIDTH, _buf, Grid.M_ENEMY)
			var kept := 0
			var band := BEAM_HALF_WIDTH + ENEMY_RADIUS
			for k in mini(n2, _buf.size()):
				var j := Grid.index_of(_buf[k])
				var rel := enemies.pos[j] - at
				var along := rel.dot(dir)
				if along < 0.0 or along > r.radius:
					continue
				if absf(rel.cross(dir)) > band:
					continue
				_beam_hits[kept] = j
				_beam_keys[kept] = along
				kept += 1
			# Select the pierce + 1 nearest by (projection, index): a total order,
			# so equal projections resolve the same on every peer. O(n x k).
			var want := mini(int(r.pierce) + 1, kept)
			for s2 in want:
				var best := s2
				for c in range(s2 + 1, kept):
					if _beam_keys[c] < _beam_keys[best] \
							or (_beam_keys[c] == _beam_keys[best] and _beam_hits[c] < _beam_hits[best]):
						best = c
				if best != s2:
					var tj := _beam_hits[s2]; _beam_hits[s2] = _beam_hits[best]; _beam_hits[best] = tj
					var tk := _beam_keys[s2]; _beam_keys[s2] = _beam_keys[best]; _beam_keys[best] = tk
				_hit(ei, r, _beam_hits[s2])
		Module.VectorKind.CONE:
			# A broadcast query filtered by ANGLE around the owner's facing.
			var cdir: Vector2 = player_facing[owner]
			_fx.append([FxKind.WEDGE, at, cdir, r.radius, FX_LIFE, Color(2.0, 1.6, 0.8)])
			var cn := grid.query_radius_into(at, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(cn, _buf.size()):
				var cj := Grid.index_of(_buf[k])
				var to_e := enemies.pos[cj] - at
				if to_e.length_squared() < 0.01:
					_hit(ei, r, cj)
					continue
				if absf(to_e.normalized().angle_to(cdir)) <= CONE_HALF_ANGLE:
					_hit(ei, r, cj)
		Module.VectorKind.PULSE:
			_fx.append([FxKind.PULSE, at, Vector2.RIGHT, r.radius, FX_LIFE * 1.6, Color(0.9, 1.4, 2.2)])
			var pn := grid.query_radius_into(at, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(pn, _buf.size()):
				var pj := Grid.index_of(_buf[k])
				_hit(ei, r, pj)
				if r.knockback > 0.0:
					var away := enemies.pos[pj] - at
					if away.length_squared() > 0.01:
						apply_knockback(pj, away.normalized() * r.knockback)
		Module.VectorKind.MINE:
			# A projectile with no velocity and a proximity fuse, so mines cost
			# no new population and inherit terrain collision for free.
			var mines: int = maxi(int(r.split_count), 1)
			var back: Vector2 = player_facing[owner]
			var centre := at - back * MINE_DROP
			for sm in mines:
				var mat := centre
				if mines > 1:
					# The ring is rotated so one vertex lies on the facing axis
					# (nearest the owner), by complex multiply — no new
					# transcendental enters the tick.
					var v := Vector2(MINE_SPREAD, 0.0).rotated(TAU * float(sm) / float(mines))
					mat = centre + Vector2(v.x * back.x - v.y * back.y, v.x * back.y + v.y * back.x)
				# Behind the owner may be rock — the owner's position is
				# walkable, a step behind it need not be — so every mine, single
				# or ring, goes through nearest_open.
				mat = terrain.nearest_open(mat)
				var mi := projectiles.spawn(mat, Vector2.ZERO, 1.0,
					PROJECTILE_RADIUS, 0)
				if mi < 0:
					break
				_proj_owner[mi] = ei
				_proj_pierce[mi] = 0
				_proj_last[mi] = -1
				_proj_dist_left[mi] = 1.0
				_proj_target[mi] = -1
				_proj_target_gen[mi] = -1
				_proj_reacquire[mi] = 0.0
				_mine_left[mi] = MINE_LIFE
				_orbit_left[mi] = 0.0
		Module.VectorKind.ORBIT:
			# Orbiters live exactly one cadence, so refiring REPLACES the ring
			# rather than stacking a second one on top of it.
			var count: int = maxi(int(r.orbit_count), 1)
			for k in count:
				var oi := projectiles.spawn(at, Vector2.ZERO, 1.0,
					PROJECTILE_RADIUS, 0)
				if oi < 0:
					break
				_proj_owner[oi] = ei
				_proj_pierce[oi] = 999
				_proj_last[oi] = -1
				_proj_dist_left[oi] = 1.0
				_proj_target[oi] = -1
				_proj_target_gen[oi] = -1
				_proj_reacquire[oi] = 0.0
				_mine_left[oi] = 0.0
				_orbit_phase[oi] = TAU * float(k) / float(count)
				_orbit_left[oi] = r.cooldown
		Module.VectorKind.CHAIN:
			var t2 := _pick_target(r.radius, r.targeting, at)
			if t2 < 0:
				return
			_hit(ei, r, t2)
			_fx.append([FxKind.BOLT, at, enemies.pos[t2] - at, 0.0, FX_LIFE, Color(1.0, 2.2, 1.6)])
			var from := enemies.pos[t2]
			var visited := [t2]
			var hops := 0
			while hops < r.chain_count:
				var n3 := grid.query_radius_into(from, 120.0, _buf, Grid.M_ENEMY)
				var picked := -1
				for k in mini(n3, _buf.size()):
					var j := Grid.index_of(_buf[k])
					# Excluding only the ORIGINAL target let every hop re-select
					# the enemy it had just jumped from — that enemy sits at
					# distance 0 from the query point. chain_count scaled nothing
					# but repeat hits on one target.
					if not (j in visited):
						picked = j
						break
				if picked < 0:
					break
				_hit(ei, r, picked)
				_fx.append([FxKind.BOLT, from, enemies.pos[picked] - from, 0.0, FX_LIFE, Color(1.0, 2.2, 1.6)])
				visited.append(picked)
				from = enemies.pos[picked]
				hops += 1
		_:
			# Along the owner's facing, no target pick — except a homing fused
			# module, which binds a target at spawn and launches TOWARD it: a
			# seeker launched away would spend most of its travel coming about.
			# (VIEW_RANGE: the viewport covers ~1113x626 world units at this
			# zoom, so the corner is ~640 away; a wider pick let seekers bind to
			# enemies well off-screen and walked the entire grid.)
			var t3 := -1
			var dir2: Vector2 = player_facing[owner]
			if r.homing > 0.0:
				t3 = _pick_target(VIEW_RANGE, r.targeting, at)
				if t3 >= 0:
					dir2 = (enemies.pos[t3] - at).normalized()
			_fx.append([FxKind.DASH, at, dir2, 26.0, FX_LIFE, Color(1.1, 1.7, 1.4)])
			var shots: int = maxi(int(r.split_count), 1)
			for sp in shots:
				# Centred on the aim: 1 shot is dead on, 3 is -spread/0/+spread.
				var off := (float(sp) - float(shots - 1) * 0.5) * SPLIT_SPREAD
				var pi := projectiles.spawn(at,
					dir2.rotated(off) * maxf(r.projectile_speed, 120.0),
					1.0, PROJECTILE_RADIUS, 0)
				if pi < 0:
					break
				_proj_owner[pi] = ei
				_proj_pierce[pi] = r.pierce
				_proj_last[pi] = -1
				_proj_dist_left[pi] = maxf(r.travel, 1.0)
				_proj_target[pi] = t3
				_proj_target_gen[pi] = enemies.generation[t3] if t3 >= 0 else -1
				_proj_reacquire[pi] = 0.0
				# Slots are recycled: without this an ordinary shot landing on a
				# slot that was last a mine would sit still and never fly.
				_mine_left[pi] = 0.0
				_orbit_left[pi] = 0.0

## `from` is where the shot came from. Defaults to the OWNING player, which is
## true for broadcast, chain and beam; packets pass their own position, because a
## packet that flew round behind something did not hit it from the front.
func _hit(ei: int, r: ResolvedExploit, target: int,
		from: Vector2 = Vector2.INF) -> void:
	if target < 0 or target >= enemies.count:
		return
	if from == Vector2.INF:
		from = player_pos[maxi(_owner_slot(ei), 0)]
	queue.append(HitQueue.Kind.DAMAGE, ei, target, enemies.generation[target],
		r.damage * _facing_scale(target, from))
	if r.corruption > 0.0 and r.has_tag(&"corruption"):
		queue.append(HitQueue.Kind.CORRUPTION, ei, target, enemies.generation[target], r.corruption)

## How much of a hit lands, given where it came from.
##
## packet_filter is the first enemy whose POSITION relative to you matters more
## than your damage: flanking it is a manoeuvre rather than a stat check. Facing
## is its movement direction, so it turns as it repositions.
##
## Here, where the source is known — not in the drain, which would have to read
## facing for every enemy on every hit whether or not one of these is alive.
## A mine going off is a broadcast at its own position, which is why MINE needed
## no new hit path — only a fuse.
## A detonation is a broadcast at the projectile's own position. Mines have
## always been this; blast_radius lets a flying packet do it too, which is why
## `radius` is a PARAMETER rather than read from the exploit — a MINE detonates
## in r.radius and a packet in r.blast_radius.
func _detonate(i: int, radius: float) -> void:
	var ei := _proj_owner[i]
	var r := _resolved(ei)
	if r != null and radius > 0.0:
		feel.add_trauma(0.15)
		_fx.append([FxKind.BLAST, projectiles.pos[i], Vector2.RIGHT, radius, FX_LIFE * 1.5, Color(2.2, 1.2, 0.5)])
		var n := grid.query_radius_into(projectiles.pos[i], radius, _buf,
			Grid.M_ENEMY)
		for k in mini(n, _buf.size()):
			_hit(ei, r, Grid.index_of(_buf[k]), projectiles.pos[i])
	_mine_left[i] = 0.0
	projectiles.state[i] = Population.DEAD

## A projectile that STOPS — out of travel, into a wall, or out of pierce —
## detonates if it carries a blast, and simply dies otherwise.
func _expire_projectile(i: int) -> void:
	var r := _resolved(_proj_owner[i])
	if r != null and r.blast_radius > 0.0:
		_detonate(i, r.blast_radius)
		return
	projectiles.state[i] = Population.DEAD

func apply_knockback(i: int, impulse: Vector2) -> void:
	if i < 0 or i >= _knock.size():
		return
	_knock[i] += impulse

func _facing_scale(i: int, from: Vector2) -> float:
	if i < 0 or i >= enemies.count or enemies.type_index[i] != _packet_filter_index:
		return 1.0
	var facing := enemies.vel[i]
	if facing.length_squared() < 0.01:
		return 1.0
	# The half-plane: everything in front of its shoulders, not a narrow cone.
	# POSITIVE dot means the shot arrived from the direction it is facing — that
	# is its front. The reverse reading armours its back and leaves the shield
	# side open, which plays as the exact opposite mechanic.
	if (from - enemies.pos[i]).normalized().dot(facing.normalized()) > 0.0:
		return FILTER_FRONT_SCALE
	return 1.0

## One linear pass over the enemies in range, with the comparator chosen by the
## exploit. Same scan, same cost — enemies.integrity is already in hand, so
## STRONGEST adds no work the distance sort did not do.
##
## `from` is where the scan SCORES from — the firing slot's position on the
## fire paths, or a homing projectile's own position in flight, since a shot
## behind the swarm would otherwise re-acquire across the arena. Required, so no
## caller silently scans from "the player" when there are four.
func _pick_target(within: float, mode: int, from: Vector2) -> int:
	var n := grid.query_radius_into(from, within, _buf, Grid.M_ENEMY)
	var best := -1
	var score := INF
	for k in mini(n, _buf.size()):
		var j := Grid.index_of(_buf[k])
		var s: float
		match mode:
			Module.Targeting.STRONGEST: s = -enemies.integrity[j]
			Module.Targeting.FARTHEST:  s = -enemies.pos[j].distance_squared_to(from)
			_:                          s = enemies.pos[j].distance_squared_to(from)
		if s < score:
			score = s
			best = j
	return best

func _step6_detect(dt: float) -> void:
	# Projectiles. _proj_last is the hit memory: without it a stateless overlap
	# test re-hits the same enemy every tick it overlaps, so damage would scale
	# INVERSELY with projectile speed and pierce would have no meaning.
	for i in projectiles.count:
		# Travel expiry marks projectiles dead back in step 2, so a dead one can
		# reach this loop — it could not before, and without this guard it still
		# lands a hit on its expiry tick.
		if projectiles.state[i] != Population.ALIVE:
			continue
		var n := grid.query_radius_into(projectiles.pos[i],
			PROJECTILE_RADIUS + ENEMY_RADIUS, _buf, Grid.M_ENEMY)
		for k in mini(n, _buf.size()):
			var j := Grid.index_of(_buf[k])
			if j == _proj_last[i]:
				continue
			var ei := _proj_owner[i]
			var pr := _resolved(ei)
			if pr != null:
				_hit(ei, pr, j, projectiles.pos[i])
			_proj_last[i] = j
			_proj_pierce[i] -= 1
			if _proj_pierce[i] < 0:
				# The same exit as running out of travel: a blast goes off where
				# the shot stopped, whatever stopped it. Note the enemy that
				# consumed the last pierce takes BOTH the contact hit above and
				# the blast — _proj_last gates the contact sweep, not the blast —
				# so a blast build's single-target damage is doubled on impact.
				_expire_projectile(i)
			break

	# Botnet auras.
	for i in botnet.count:
		var n2 := grid.query_radius_into(botnet.pos[i], 70.0, _buf, Grid.M_ENEMY)
		for k in mini(n2, _buf.size()):
			var j := Grid.index_of(_buf[k])
			queue.append(HitQueue.Kind.DAMAGE, -1, j, enemies.generation[j],
				_botnet_ratio[i] * dt)

	# Player contact and pickups, for EVERY LIVE slot independently. Enemies are
	# not physics bodies, so contact is a grid query — an Area2D cannot overlap
	# a packed array. A shard goes to the first slot to reach it in slot order:
	# a later slot's query sees it already DEAD and skips it, so nothing is
	# collected twice.
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] != SlotState.LIVE:
			continue
		var lp := player_pos[s]
		if player_iframe[s] <= 0.0:
			var n3 := grid.query_radius_into(lp, PLAYER_RADIUS + ENEMY_RADIUS,
				_buf, Grid.M_ENEMY)
			if n3 > 0:
				var t = enemy_types[enemies.type_index[Grid.index_of(_buf[0])]]
				_damage_player(s, t.contact_damage)
		var n4 := grid.query_radius_into(lp, pickup_radius[s], _buf, Grid.M_SHARD)
		for k in mini(n4, _buf.size()):
			var sj := Grid.index_of(_buf[k])
			if shards.state[sj] != Population.ALIVE:
				continue
			shards.state[sj] = Population.DEAD
			_gain_xp(1)

func _damage_player(slot: int, amount: float) -> void:
	# Triggers BEFORE the subtraction, so an on_damage_taken ward is up for the
	# hit that summoned it rather than the next one. ON_DAMAGE_TAKEN fires per
	# damage instance this player actually takes — not from a loop over
	# terminally-marked entities, which would fire it once per run, at game over
	# — and only from the HURT slot's own build.
	#
	# No recursion: the path is _try_event_fire -> _emit_vector -> _hit ->
	# queue.append, and nothing re-enters here.
	for ei in _slot_exploits(slot):
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_DAMAGE_TAKEN:
			_try_event_fire(ei, r)
	# The shield is in the way, so it pays first and unmitigated: armour reducing
	# a hit the shield was going to eat entirely would make the two multiply.
	if player_shield[slot] > 0.0:
		var eaten := minf(player_shield[slot], amount)
		player_shield[slot] -= eaten
		amount -= eaten
		if amount <= 0.0:
			player_iframe[slot] = IFRAMES
			emit_signal("stats_changed")
			return
	player_health[slot] -= _mitigated(slot, amount)
	var cap := _eff_integrity(slot)
	# Proportional, and the RATIO is clamped: a pulse or a hazard tick can
	# exceed full integrity, and an unclamped ratio would put trauma past 1.0
	# where MAX_OFFSET stops being a maximum. Feel is local presentation, so it
	# reacts to the LOCAL slot's hurt.
	if slot == local_slot:
		feel.add_trauma(0.25 + 0.5 * clampf(amount / maxf(cap, 1.0), 0.0, 1.0))
		feel.emit("hurt")
		_vignette = 1.0
	player_iframe[slot] = IFRAMES
	if _low_armed[slot] != 0 and player_health[slot] < cap * LOW_INTEGRITY_FRACTION:
		_low_armed[slot] = 0
		if slot == local_slot:
			feel.emit("low_integrity")
		_fire_trigger_for(slot, Module.TriggerKind.ON_LOW_INTEGRITY)
	elif player_health[slot] >= cap * LOW_INTEGRITY_FRACTION:
		_low_armed[slot] = 1
	if player_health[slot] <= 0.0 and slot_state[slot] == SlotState.LIVE and not won:
		_die(slot)
	emit_signal("stats_changed")

## Fire every exploit on ONE slot's build whose trigger matches.
func _fire_trigger_for(slot: int, kind: int) -> void:
	for ei in _slot_exploits(slot):
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == kind:
			_try_event_fire(ei, r)

## Extracted so the zone pass can reach it: a hazard kills exactly the way a
## swarm does, and two copies of the banking rules would drift. Per SLOT: the
## slot goes DEAD and banks; the run only ends when no slot is LIVE.
func _die(slot: int) -> void:
	player_health[slot] = 0.0
	slot_state[slot] = SlotState.DEAD
	# A dead slot cannot hold a round open: its offers resolve to their first
	# option at once.
	_resolve_offer_on_slot_exit(slot)
	if slot == local_slot:
		# Both of these only animate because _present() runs above the tick guard.
		feel.add_trauma(0.7)
		feel.emit("death")
	# The freeze is SIMULATION, not presentation: every peer's world holds for
	# the same ticks on the same death, or the hashes part company right here.
	_hitstop()
	# Salvage is lost, but kills and flips still count toward unlocks —
	# otherwise a losing run gives nothing and the meta has no reason to exist
	# after a death, which is exactly what it is for. The watermark moves on
	# every peer; only the owning process writes its save.
	_bank_slot(slot, false)
	alive = _any_live()
	if not alive:
		_terminal(NetworkSession.Outcome.LOSS)

## The STRONGER slow wins, never the most recent. Letting the latest write win
## means walking out of a heavy slow into a light one cancels the heavy one, so
## the weakest source in the game would become a cleanse.
## Population.spawn recycles slots, so a fresh enemy can land on an index whose
## previous occupant was slowed. A stale slow is a live bug, not a cosmetic one:
## it makes a newly spawned enemy crawl for no reason the player can see.
func _clear_ai(i: int) -> void:
	_knock[i] = Vector2.ZERO
	_split_gen[i] = 0
	_rewarded[i] = 0
	_ai_phase[i] = 0
	_ai_timer[i] = 0.0
	_ai_aim[i] = Vector2.ZERO
	_submerged[i] = 0

## Everything a freshly spawned enemy slot needs, in one place, so that adding a
## per-enemy array later cannot leave one spawn site behind — which is exactly
## how a stale-slot bug gets in.
## Move every run.gd-side per-enemy array from the tail slot into slot `i`.
##
## `Population.despawn` swap-removes the tail into `i` for ITS OWN arrays only,
## so everything parallel to them has to follow by hand. This used to be an
## inline block at the one despawn site that knew about it; it is a function
## because there are TWO such sites — `_step9_recycle` and `_step2d_collapse`,
## whose `is_void` predicate is conditional and therefore not tail-only — and a
## second copy would have drifted the moment either changed.
##
## `_submerged` and the three `_ai_*` arrays were absent from the original block
## entirely. An ambusher hid the bug by rewriting `_submerged` every tick from
## `_ambush`; the AI arrays did not, so a compacted enemy inherited a stranger's
## dash phase. `_order` is deliberately NOT here — `_depth_sort` refills it
## wholesale every tick.
func _relocate_enemy(i: int, last: int) -> void:
	_worm_id[i] = _worm_id[last]
	_worm_seg[i] = _worm_seg[last]
	_spawn_hp[i] = _spawn_hp[last]
	_slow_left[i] = _slow_left[last]
	_slow_factor[i] = _slow_factor[last]
	_knock[i] = _knock[last]
	_split_gen[i] = _split_gen[last]
	_rewarded[i] = _rewarded[last]
	_hit_flash[i] = _hit_flash[last]
	_arriving[i] = _arriving[last]
	_submerged[i] = _submerged[last]
	_ai_phase[i] = _ai_phase[last]
	_ai_timer[i] = _ai_timer[last]
	_ai_aim[i] = _ai_aim[last]
	_enemy_target[i] = _enemy_target[last]

func _spawn_enemy_state(i: int, hp: float,
		behaviour: int = EnemyTable.Behaviour.CHASE) -> void:
	_worm_id[i] = 0
	_enemy_target[i] = -1
	_clear_slow(i)
	_clear_ai(i)
	_spawn_hp[i] = hp
	_hit_flash[i] = 0.0
	_arriving[i] = 0.0
	if behaviour == EnemyTable.Behaviour.AMBUSHER:
		# A fresh ambusher owes a full submerged run before its first surface;
		# a zero timer would have it breaching on the tick it spawned.
		_ai_timer[i] = AMBUSH_UNDER
		_submerged[i] = 1

## Which way this enemy should walk to close on the player.
##
## The straight line for the swarm — a hundred of them shouldering through each
## other around a wall IS what a swarm looks like, and a flood per enemy would
## be the most expensive thing in the tick. Bosses get the flow field, because
## one large object stuck on a corner while the player circles it is not a
## fight, and it is the failure the player actually notices.
##
## Falls back to the straight line whenever the field has no gradient — outside
## its window, or walled in — so this can only ever be as bad as the old
## behaviour.
func _approach_dir(i: int, to_player: Vector2) -> Vector2:
	var straight := to_player.normalized()
	var ti := enemies.type_index[i]
	if ti != EnemyTable.ICE and not _is_miniboss(ti):
		return straight
	var f: Vector2 = _flow[_target_slot].dir_at(terrain, enemies.pos[i])
	return f if f != Vector2.ZERO else straight

## The desired velocity for one enemy, before separation and avoidance forces.
##
## A match in a loop that already runs, so a CHASE enemy costs one branch. The
## alternative — an object per enemy with a virtual step — would put six hundred
## allocations and six hundred virtual calls in the hot path to express six
## cases.
func _behave(i: int, t, dt: float) -> Vector2:
	var sp: float = t.speed
	if _slow_left[i] > 0.0:
		sp *= _slow_factor[i]
	# ONE target for the whole decision, scanned inline over the packed LIVE
	# cache and remembered per enemy for the steer and reapproach passes.
	# Nobody LIVE means nothing to chase.
	var nlive := _live_pos.size()
	if nlive == 0:
		_enemy_target[i] = -1
		_target_slot = 0
		return Vector2.ZERO
	var ep := enemies.pos[i]
	var mk := 0
	var md := ep.distance_squared_to(_live_pos[0])
	for k in range(1, nlive):
		var dk := ep.distance_squared_to(_live_pos[k])
		if dk < md:
			md = dk
			mk = k
	_target_slot = _live_of[mk]
	_enemy_target[i] = _target_slot
	var to_player := player_pos[_target_slot] - ep
	match t.behaviour:
		EnemyTable.Behaviour.CHARGER:
			return _charge(i, sp, to_player, dt)
		EnemyTable.Behaviour.FLANKER:
			return _flank(i, sp, to_player)
		EnemyTable.Behaviour.SUPPORT:
			return _support(i, sp, to_player, dt)
		EnemyTable.Behaviour.AMBUSHER:
			return _ambush(i, sp, to_player, dt)
		EnemyTable.Behaviour.RANGED:
			return _ranged(i, sp, to_player, dt)
		_:
			return _approach_dir(i, to_player) * sp
	return _approach_dir(i, to_player) * sp

## Approach, telegraph, commit, overshoot.
##
## The direction is locked at the MOMENT the dash begins and never revisited.
## That is the whole design: a dash that keeps tracking you during the dash
## cannot be dodged and reads as the game cheating, while one that commits is a
## timing puzzle with a fair answer — sidestep late. The overshoot is the
## reward for reading it.
func _charge(i: int, sp: float, to_player: Vector2, dt: float) -> Vector2:
	_ai_timer[i] -= dt
	match _ai_phase[i]:
		CH_APPROACH:
			if to_player.length() <= CHARGE_RANGE:
				_ai_phase[i] = CH_WINDUP
				_ai_timer[i] = CHARGE_WINDUP
				return Vector2.ZERO
			return _approach_dir(i, to_player) * sp
		CH_WINDUP:
			if _ai_timer[i] <= 0.0:
				_ai_phase[i] = CH_DASH
				_ai_timer[i] = CHARGE_DASH
				_ai_aim[i] = to_player.normalized()
				return _ai_aim[i] * sp * CHARGE_SPEED
			# Still. A telegraph the player cannot see is not a telegraph.
			return Vector2.ZERO
		CH_DASH:
			if _ai_timer[i] <= 0.0:
				_ai_phase[i] = CH_RECOVER
				_ai_timer[i] = CHARGE_RECOVER
				return _ai_aim[i] * sp * 0.5
			return _ai_aim[i] * sp * CHARGE_SPEED
		_:
			if _ai_timer[i] <= 0.0:
				_ai_phase[i] = CH_APPROACH
			return to_player.normalized() * sp * 0.5

## kernel_panic's pulse: everything with LINE OF SIGHT to it takes the hit, so
## standing behind a wall is the only answer. This is the payoff for terrain
## existing, and it is why the line-of-sight walk had to be built.
func _pulse(i: int, dt: float) -> void:
	_ai_aim[i].x -= dt
	if _ai_aim[i].x > 0.0:
		return
	_ai_aim[i].x = PULSE_PERIOD
	_fx.append([FxKind.PULSE, enemies.pos[i], Vector2.RIGHT, 700.0, FX_LIFE * 8.0, Color(2.2, 0.5, 0.4)])
	# Everything with line of sight takes the hit — every LIVE slot is checked
	# on its own, so cover is per player.
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.LIVE \
				and terrain.has_line_of_sight(enemies.pos[i], player_pos[s]):
			_damage_player(s, PULSE_DAMAGE)

## Holds its distance and shoots, leading the player.
func _ranged(i: int, sp: float, to_player: Vector2, dt: float) -> Vector2:
	if enemy_types[enemies.type_index[i]].id == &"kernel_panic":
		_pulse(i, dt)
	_ai_timer[i] -= dt
	if _ai_timer[i] <= 0.0:
		_ai_timer[i] = RANGED_COOLDOWN
		_fire_hostile(enemies.pos[i])
	var d := to_player.length()
	if d < 0.001:
		return Vector2.ZERO
	var toward := to_player / d
	if d > RANGED_STANDOFF + 60.0:
		return _approach_dir(i, to_player) * sp
	if d < RANGED_STANDOFF - 60.0:
		return -toward * sp
	return Vector2.ZERO

func _fire_hostile(from: Vector2) -> void:
	# Lead the TARGET player, so standing still is punished and moving is rewarded.
	var lead := player_pos[_target_slot] + player_vel[_target_slot] * 0.35
	var dir := (lead - from).normalized()
	var h := hostiles.spawn(from, dir * HOSTILE_SPEED, 1.0, HOSTILE_RADIUS, 0)
	if h >= 0:
		_hostile_life[h] = 4.0

## Hostile shots: move, expire, die on terrain, and hit exactly one thing.
func _step6b_hostiles(dt: float) -> void:
	var i := 0
	while i < hostiles.count:
		hostiles.pos[i] += hostiles.vel[i] * dt
		_hostile_life[i] -= dt
		var gone := _hostile_life[i] <= 0.0 or terrain.is_solid(hostiles.pos[i])
		# A shot hits exactly one thing: the first LIVE slot it touches, in slot
		# order.
		if not gone:
			for s in SessionRules.MAX_PLAYERS:
				if slot_state[s] != SlotState.LIVE:
					continue
				if hostiles.pos[i].distance_to(player_pos[s]) \
						< HOSTILE_RADIUS + PLAYER_RADIUS:
					_damage_player(s, HOSTILE_DAMAGE)
					gone = true
					break
		if gone:
			hostiles.despawn(i)
			continue        # despawn swaps the last element in; do NOT advance
		i += 1

## Hangs back and heals the swarm, which makes it a priority target you have to
## dig for — a target-selection decision the game does not otherwise have.
##
## Healing rather than shielding, deliberately. A damage-reduction shield has to
## be read inside HitQueue.drain_pass for EVERY enemy on every hit, whether or
## not a support is alive; healing is a bounded write from the support's own
## step and touches nothing else. Both produce the same decision for the player
## and only one of them taxes the drain.
func _support(i: int, sp: float, to_player: Vector2, dt: float) -> Vector2:
	var n := grid.query_radius_into(enemies.pos[i], SUPPORT_RADIUS, _buf,
		Grid.M_ENEMY)
	for k in mini(n, _buf.size()):
		var j := Grid.index_of(_buf[k])
		if j == i or enemies.state[j] != Population.ALIVE:
			continue
		# The cap is the HP its type and subnet gave it at spawn, so a healer can
		# restore an enemy but never inflate one.
		enemies.integrity[j] = minf(_spawn_hp[j],
			enemies.integrity[j] + SUPPORT_HEAL * dt)
		# Remembered for the draw: a heal nobody can see is a fight the player
		# is losing for reasons they cannot name. Last one wins — the link is a
		# tell that healing IS happening and where, not an audit of every
		# recipient.
		_ai_aim[i] = enemies.pos[j]
	var d := to_player.length()
	if d < 0.001:
		return Vector2.ZERO
	var toward := to_player / d
	if d > SUPPORT_STANDOFF + 40.0:
		return _approach_dir(i, to_player) * sp
	if d < SUPPORT_STANDOFF - 40.0:
		return -toward * sp
	return Vector2.ZERO

## Drops out of the field, travels unseen, surfaces on you.
##
## The SURFACING tell is not decoration. An enemy that appears on top of you
## with no warning is the thing players correctly call cheap; the tell is what
## makes it a punishment for tunnel vision rather than an ambush nobody could
## have avoided.
func _ambush(i: int, sp: float, to_player: Vector2, dt: float) -> Vector2:
	_ai_timer[i] -= dt
	match _ai_phase[i]:
		AM_SUBMERGED:
			if _submerged[i] == 0 and enemy_types[enemies.type_index[i]].id == &"null_ptr":
				_leave_afterimage(enemies.pos[i])
			_submerged[i] = 1
			if _ai_timer[i] <= 0.0:
				_ai_phase[i] = AM_SURFACING
				_ai_timer[i] = AMBUSH_SURFACING
				return Vector2.ZERO
			return to_player.normalized() * sp * AMBUSH_SPEED
		AM_SURFACING:
			_submerged[i] = 1
			if _ai_timer[i] <= 0.0:
				_ai_phase[i] = AM_ACTIVE
				_ai_timer[i] = AMBUSH_ACTIVE
				_submerged[i] = 0
			# Still, and visible as a tell, while it comes up.
			return Vector2.ZERO
		_:
			_submerged[i] = 0
			if _ai_timer[i] <= 0.0:
				_ai_phase[i] = AM_SUBMERGED
				_ai_timer[i] = AMBUSH_UNDER
				_submerged[i] = 1
			return to_player.normalized() * sp

## Steer at where the player is GOING, plus a tangential bias so it arcs around
## rather than converging head-on.
##
## This is what makes terrain bite: a flanker closes the lane you were kiting
## toward, and a wall behind you turns that into a real mistake. Against a
## stationary player the lead term vanishes and it degenerates to a chase, which
## is correct — there is no escape to cut off.
func _flank(i: int, sp: float, to_player: Vector2) -> Vector2:
	var pv := player_vel[_target_slot]
	var lead := to_player + pv * FLANK_LEAD
	if lead.length_squared() < 0.0001:
		return to_player.normalized() * sp
	var dir := lead.normalized()
	# Tangential component scaled by how fast the player is ACTUALLY moving:
	# circling a stationary target is just a worse chase.
	var speed_frac := clampf(pv.length() / 220.0, 0.0, 1.0)
	var tangent := Vector2(-dir.y, dir.x)
	# Arc the way the player is GOING. Either perpendicular is a valid tangent
	# and the wrong one swings out behind them — which is a chase with extra
	# steps, and at this magnitude it could even cancel the lead entirely.
	if tangent.dot(pv) < 0.0:
		tangent = -tangent
	return (dir + tangent * FLANK_TANGENT * speed_frac).normalized() * sp

func _clear_slow(i: int) -> void:
	_slow_left[i] = 0.0
	_slow_factor[i] = 1.0

func apply_slow(i: int, factor: float, seconds: float) -> void:
	if _slow_left[i] <= 0.0 or factor < _slow_factor[i]:
		_slow_factor[i] = factor
	_slow_left[i] = maxf(_slow_left[i], seconds)

## Zone effects, one array index per entity per tick.
func _step2b_zones(dt: float) -> void:
	_zone_slow_player.fill(0)
	terrain.step_temp_zones(dt)
	# Every LIVE slot stands in its own zone, independently.
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] != SlotState.LIVE:
			continue
		var pz := terrain.zone_at(player_pos[s])
		if pz < 0:
			pz = terrain.temp_zone_at(player_pos[s])
		if pz == Terrain.Kind.HAZARD:
			# Deliberately NOT through the contact-damage path: iframes exist to
			# stop a swarm chewing through you on touch, and a hazard you are
			# standing in is not a contact event. Armour and defence still apply.
			player_health[s] -= _mitigated(s, Terrain.HAZARD_DPS * dt)
			if player_health[s] <= 0.0 and not won:
				_die(s)
		elif pz == Terrain.Kind.SLOW:
			_zone_slow_player[s] = 1
	var zo: Vector2 = terrain.origin
	var zw: int = terrain.w
	var zh: int = terrain.h
	var zone: PackedByteArray = terrain.zone
	var zinv := 1.0 / Terrain.CELL
	for i in enemies.count:
		if _slow_left[i] > 0.0:
			_slow_left[i] -= dt
		# Out of the grid stops the PLAYER touching it; it does not stop the
		# floor. This pass queues damage and corruption purely by index, and
		# corruption is the flip channel — so without this an arriving ICE could
		# flip mid-entrance, invisible, and the flip guard, the boss spawn and
		# the win condition all key off EnemyTable.ICE.
		if _arriving[i] > 0.0:
			continue
		# The baked zone grid, indexed INLINE: six hundred calls into
		# terrain.zone_at a tick were most of this step's cost, and the lookup
		# is a floor, a bounds check and one byte read.
		var ep := enemies.pos[i]
		var zx := int(floor((ep.x - zo.x) * zinv))
		var zy := int(floor((ep.y - zo.y) * zinv))
		if zx < 0 or zy < 0 or zx >= zw or zy >= zh:
			continue
		match int(zone[zy * zw + zx]) - 1:
			Terrain.Kind.HAZARD:
				queue.append(HitQueue.Kind.DAMAGE, -1, i, enemies.generation[i],
					Terrain.HAZARD_DPS * dt)
			Terrain.Kind.SLOW:
				apply_slow(i, Terrain.SLOW_FACTOR, 0.5)
			Terrain.Kind.CORRUPTION:
				queue.append(HitQueue.Kind.CORRUPTION, -1, i,
					enemies.generation[i], Terrain.CORRUPTION_PER_SEC * dt)

func _steps78_drain() -> void:
	for pass_i in CASCADE_PASSES:
		if queue.count == 0 and queue.hit_count == 0:
			break
		var hits_before := queue.hit_count
		var resolved_n := queue.drain_pass(enemies, thresholds, _spawn_hp,
			_execute_by_exploit, _execute_immune_type)

		# Flash every target hit in THIS pass: 0 ..< hit_count, not
		# hits_before ..< hit_count. `drain_pass` zeroes hit_count on entry
		# (hit_queue.gd), so `hits_before` holds the PREVIOUS pass's count — a
		# range built from it is empty whenever a pass lands fewer hits than the
		# one before, and skips an arbitrary prefix otherwise. Silently, since
		# the indices stay in bounds.
		for k in queue.hit_count:
			var ht := queue.hit_target[k]
			if ht >= 0 and ht < enemies.count:
				_hit_flash[ht] = 1.0
				# How solid the thing felt. The player lands hundreds of these
				# a run, so it is the cheapest channel the game has for
				# information the HUD would need a health bar per enemy to show.
				feel.emit(HIT_SOUNDS[_hit_weight[enemies.type_index[ht]]])
				if _numbers_pref:
					var hr := _resolved(queue.hit_exploit[k])
					var dmg: float = hr.damage if hr != null else 0.0
					if dmg >= 1.0:
						feel.add_number(enemies.pos[ht], "%d" % int(dmg),
							Color(1.0, 1.9, 1.4))

		# ON_HIT fires per hit on an OPEN target, regardless of outcome. Gating
		# it on death makes the cascade the fire budget exists for impossible.
		# Fires on ANY hit the player landed, not only the owning exploit's.
		# Self-attribution makes ON_HIT depend on its own output, which cannot
		# bootstrap. Fired once per pass, not once per hit, so a 300-enemy aura
		# cannot turn one tick into N**8 events.
		if queue.hit_count > hits_before:
			# For each SLOT that landed a hit this pass — any exploit of that
			# slot's build, not only the one that hit, because self-attribution
			# cannot bootstrap — but never another player's build.
			var hit_mask := 0
			for k in queue.hit_count:
				var hs := _owner_slot(queue.hit_exploit[k])
				if hs >= 0:
					hit_mask |= 1 << hs
			for s in SessionRules.MAX_PLAYERS:
				if (hit_mask & (1 << s)) != 0:
					_fire_trigger_for(s, Module.TriggerKind.ON_HIT)

		# Break only when nothing resolved AND nothing new is queued. Breaking on
		# resolved_n alone discarded the events ON_HIT had just appended one line
		# above, so ON_HIT contributed nothing in any tick whose pass killed
		# nothing — the ordinary case the trigger exists for.
		if resolved_n == 0 and queue.count == 0:
			break

		# Consume each verdict as it is dispatched. outcome[] persists for the
		# whole tick and enemies.state[] until step 9, so an enemy resolved in
		# pass 1 matched again in every later pass: kills, shards, ON_KILL
		# cascades, lifesteal and botnet spawns all multiplied by cascade depth.
		# HitQueue held "adjudicated exactly once"; this loop, its only consumer,
		# broke it.
		if resolved_n > 0:
			for i in enemies.count:
				var o := queue.outcome[i]
				if o == HitQueue.Outcome.NONE:
					continue
				queue.outcome[i] = HitQueue.Outcome.NONE
				if o == HitQueue.Outcome.DEAD and enemies.state[i] == Population.DEAD:
					_on_death(i)
				elif o == HitQueue.Outcome.FLIPPED and enemies.state[i] == Population.FLIPPED:
					_on_flip(i)

func _on_death(i: int) -> void:
	# Credited to the OWNER of the killing exploit. An unowned kill — a botnet
	# aura, a hazard, the collapse — credits nobody: -1 decodes to no slot.
	var killer_gid := queue.killer_exploit[i]
	var ks := _owner_slot(killer_gid)
	if ks >= 0:
		kills[ks] += 1
	feel.emit("kill")
	if enemies.type_index[i] == _fork_bomb_index \
			and _split_gen[i] < SPLIT_GENERATIONS:
		# Flagged, not spawned: this runs inside the drain, and spawning here
		# pulls entities out from under a pass still adjudicating them.
		_pending_splits.append([enemies.pos[i], _split_gen[i] + 1,
			maxf(_spawn_hp[i] * 0.5, 8.0)])
	if _is_miniboss(enemies.type_index[i]) and _rewarded[i] == 0:
		# The strongest reward the game has, and deliberately so: it makes
		# engaging a real decision, and hands a struggling build the thing it
		# actually needs, which is more build.
		_rewarded[i] = 1
		salvage += MINIBOSS_SALVAGE
		pending_levels += 1
		# Before _offer_cards, which sets `paused` — the release lives above the
		# guard now, so this survives either way, but the ordering keeps the
		# emphasis on the kill rather than on the card screen opening.
		feel.add_trauma(0.45)
		feel.emit("miniboss_kill")
		_hitstop()
		_settle_offers()
	if enemies.type_index[i] == EnemyTable.ICE and not won:
		# kills is incremented FIRST: banking before it meant the kill that ends
		# a winning run was never persisted, so entering the boss at 399 kills
		# won, displayed 400, and saved 399 — silently missing the beam unlock.
		# The `not won` guard keeps a second dispatch from re-banking the run.
		feel.add_trauma(0.8)
		feel.emit("ice_kill")
		_hitstop()
		salvage += 500
		if subnet < SpawnDirector.CAMPAIGN_SUBNETS:
			# CLEARED, not advanced. The advance is the player's move now: walk
			# to the gate. Safe to set inside the drain because it is a flag and
			# a bool — nothing is spawned, freed, or moved.
			phase = Phase.CLEARED
			feel.emit("gate_open")
			terrain.open_gate()
			terrain.build_distance_field()
			collapse_left = COLLAPSE_SECONDS
			_bank_progress(true)
		else:
			won = true
			feel.emit("win")
			_bank_progress(true)
			_terminal(NetworkSession.Outcome.WIN)
	_drop_shards(i)
	# ON_KILL fires only the OWNER's build, and lifesteal heals only the owner.
	if ks >= 0:
		_fire_trigger_for(ks, Module.TriggerKind.ON_KILL)
		var killer := _resolved(killer_gid)
		if killer != null and killer.lifesteal > 0.0:
			player_health[ks] = minf(_eff_integrity(ks),
				player_health[ks] + killer.lifesteal)

## A flipped enemy drops the same shards a killed one does, so a corruption
## build does not starve its own level-ups in proportion to how well it works.
func _on_flip(i: int) -> void:
	# Credited to the flipping exploit's owner; an environmental flip (-1) or an
	# unset sentinel (-2) credits nobody and fires nobody's ON_FLIP.
	var fs := _owner_slot(queue.flipper_exploit[i])
	if fs >= 0:
		flips[fs] += 1
		_fire_trigger_for(fs, Module.TriggerKind.ON_FLIP)
	feel.emit("flip")
	_drop_shards(i)
	if botnet.count >= mini(_botnet_cap(), MAX_BOTNET):
		return
	var src := _resolved(queue.flipper_exploit[i])
	var corr := 6.0
	if src != null:
		corr = maxf(src.corruption, 1.0)
	var bi := botnet.spawn(enemies.pos[i], Vector2.ZERO, 1.0, ENEMY_RADIUS, 0)
	if bi >= 0:
		_botnet_ratio[bi] = BOTNET_BASE_RATIO * corr
		_botnet_life[bi] = BOTNET_BASE_LIFETIME

## The botnet is ONE shared pool, so its cap SUMS over every slot's build — the
## one offensive stat that folds across players rather than per owner.
func _botnet_cap() -> int:
	var cap := BOTNET_BASE_CAP
	for r in resolved:
		if r != null:
			cap += int(r.botnet_cap)
	return cap

func _drop_shards(i: int) -> void:
	var t = enemy_types[enemies.type_index[i]]
	for s in t.shard_value:
		shards.spawn(enemies.pos[i] + Vector2(_rng.randf_range(-8, 8),
			_rng.randf_range(-8, 8)), Vector2.ZERO, 1.0, 4.0, 0)

## Bring distant stragglers back around the player.
##
## MOVED, not despawned and respawned. The player-visible outcome is what was
## asked for — an enemy that fell behind reappears on the spawn ring with the
## damage you already did to it — but a despawn swap-removes the tail into the
## freed slot and every parallel array has to follow it. Moving the entity keeps
## its slot, so integrity, spawn HP, slow, knockback, AI phase and arrival timer
## all come along for free and there is no relocation to get wrong.
##
## Runs after recycle so it never touches a slot that is about to be freed.
func _step9c_reapproach() -> void:
	# FIGHTING only. Nothing is spawning during the collapse, and teleporting
	# the leftovers around a player walking to the gate would be nonsense.
	if phase != Phase.FIGHTING:
		return
	var moved := 0
	for i in enemies.count:
		if moved >= RECYCLE_PER_TICK:
			break
		if enemies.state[i] != Population.ALIVE:
			continue
		# Set-pieces are never moved: a boss that blinks across the arena is a
		# boss the player cannot fight deliberately. Worms are a chain sampled
		# off a head trail, so moving one segment tears the body apart.
		var ti3 := enemies.type_index[i]
		if ti3 == EnemyTable.ICE or _is_miniboss(ti3):
			continue
		if _worm_id[i] != 0 or _arriving[i] > 0.0:
			continue
		# Beyond the recycle radius of EVERY LIVE slot — the nearest one, chosen
		# in _behave this tick, decides — and brought back around that slot. An
		# enemy that was not behaved this tick (driven straight into this step)
		# has no cached choice and is scanned afresh.
		var ns := _enemy_target[i]
		if ns < 0:
			ns = _nearest_live(enemies.pos[i])
		if ns < 0 or player_pos[ns].distance_to(enemies.pos[i]) < RECYCLE_RADIUS:
			continue
		var a5 := _rng.randf() * TAU
		# teleport, not a bare pos write: this is the ONE discontinuous move in
		# the tick, and leaving prev_pos behind draws the straggler streaking the
		# full width of the arena for exactly one frame.
		enemies.teleport(i, _spawn_at(player_pos[ns]
			+ Vector2(cos(a5), sin(a5)) * SPAWN_RING))
		enemies.vel[i] = Vector2.ZERO
		enemies.force[i] = Vector2.ZERO
		_knock[i] = Vector2.ZERO
		# A charger mid-commit would otherwise arrive already winding up at a
		# player who never saw it approach.
		_clear_ai(i)
		moved += 1

func _step9_recycle() -> void:
	# A dead head takes its remaining segments with it: a headless chain has no
	# path to follow and would drift as a line of stragglers.
	var orphaned := {}
	for i in enemies.count:
		if enemies.state[i] != Population.ALIVE and _worm_id[i] != 0 and _worm_seg[i] == 0:
			orphaned[_worm_id[i]] = true
	if not orphaned.is_empty():
		for i in enemies.count:
			if orphaned.has(_worm_id[i]):
				enemies.state[i] = Population.DEAD
		for id in orphaned:
			_worm_trail.erase(id)
			_worm_cursor.erase(id)

	var i := 0
	while i < enemies.count:
		# FLIPPED retires the enemy slot too — it became a botnet node. Freeing
		# only DEAD leaves flipped entities in the swarm forever.
		if enemies.state[i] != Population.ALIVE:
			# Population.despawn swap-removes the tail into slot i, so every
			# parallel array must move with it — the same rule the projectile
			# block below states. Six of these were missing: a compacted enemy
			# inherited a stranger's spawn HP (which execute_below reads as its
			# maximum), slow, knockback, split generation and reward flag.
			_relocate_enemy(i, enemies.count - 1)
			enemies.despawn(i)
		else:
			i += 1
	i = 0
	while i < projectiles.count:
		if projectiles.state[i] != Population.ALIVE:
			# Population.despawn swap-removes the tail into slot i, so every
			# parallel array must move with it. Omitting this let a surviving
			# projectile inherit a dead one's owner exploit (wrong damage and
			# wrong lifesteal attribution) and its exhausted pierce.
			var last := projectiles.count - 1
			_proj_owner[i] = _proj_owner[last]
			_proj_pierce[i] = _proj_pierce[last]
			_proj_last[i] = _proj_last[last]
			_proj_dist_left[i] = _proj_dist_left[last]
			_proj_target[i] = _proj_target[last]
			_proj_target_gen[i] = _proj_target_gen[last]
			_proj_reacquire[i] = _proj_reacquire[last]
			# These three were already absent, so a compacted mine lost its fuse
			# and became an inert zero-velocity projectile. Rare with one mine at
			# a time; routine now that split_count lays three.
			_mine_left[i] = _mine_left[last]
			_orbit_left[i] = _orbit_left[last]
			_orbit_phase[i] = _orbit_phase[last]
			projectiles.despawn(i)
		else:
			i += 1
	i = 0
	while i < shards.count:
		if shards.state[i] != Population.ALIVE:
			shards.despawn(i)
		else:
			i += 1
	i = 0
	while i < botnet.count:
		if _botnet_life[i] <= 0.0:
			_botnet_life[i] = _botnet_life[botnet.count - 1]
			_botnet_ratio[i] = _botnet_ratio[botnet.count - 1]
			botnet.despawn(i)
		else:
			i += 1

# ---------------------------------------------------------------- campaign ---

## Enemy integrity for this run: the subnet/elapsed curve times the party
## factor. The party factor reads the IMMUTABLE roster size, so a death or a
## disconnect never makes the remaining players' enemies softer.
func _hp_mult() -> float:
	return SpawnDirector.hp_mult(subnet, director.elapsed) \
		* SpawnDirector.party_hp_mult(_players)

func _refresh_thresholds() -> void:
	var f := SpawnDirector.threshold_mult(subnet)
	for i in enemy_types.size():
		thresholds[i] = enemy_types[i].corruption_threshold * f

## Banking is SIMULATION state: a bank event advances the banked watermark on
## EVERY peer, so the manifests agree, and only the LOCAL slot's delta is then
## persisted — a remote slot's progress is never written into this process's
## save. Two events exist. A subnet clear (or the win) banks EVERY participant:
## each watermark advances everywhere and each process persists its own slot.
## Salvage is shared, so every slot banks the same pool; kills and flips are
## each slot's own.
func _bank_progress(with_salvage: bool) -> void:
	for slot in SessionRules.MAX_PLAYERS:
		if loadouts[slot] == null:
			continue
		_bank_slot(slot, with_salvage)

## One slot's bank event — its death — seen identically by every peer: the
## slot's watermark advances on all of them, and the process that owns the slot
## persists the delta. Nothing here branches on which peer this is except the
## write to disk.
func _bank_slot(slot: int, with_salvage: bool) -> void:
	var b: Dictionary = _banked[slot]
	if slot == local_slot:
		var s := (salvage - int(b[&"salvage"])) if with_salvage else 0
		SaveGame.bank(s, kills[slot] - int(b[&"kills"]),
			flips[slot] - int(b[&"flips"]))
	if with_salvage:
		b[&"salvage"] = salvage
	b[&"kills"] = kills[slot]
	b[&"flips"] = flips[slot]

## Carried forward: the loadout, the level, the XP, and whatever integrity the
## last subnet left. Reset: the clock, the wave table, and every live entity.
## The partial heal rewards the clear without erasing the damage a bad subnet
## did, so chip damage still accumulates across a campaign.
const SUBNET_CLEAR_HEAL := 0.30

## The arena comes apart from the far side inward, and the ground it takes is
## lethal. Runs only while CLEARED, so it costs a fighting subnet nothing.
func _step2d_collapse(dt: float) -> void:
	if phase != Phase.CLEARED:
		return
	collapse_left = maxf(0.0, collapse_left - dt)
	var threshold: int
	if collapse_left > 0.0:
		# Arena phase: the frontier walks in from the far side to the gate.
		var frac := collapse_left / COLLAPSE_SECONDS
		threshold = int(float(terrain.max_dist) * frac)
		_corridor_collapse_ticks = 0
	else:
		# Corridor phase: the arena is gone, so the threshold slides past zero
		# into the corridor's negative keys over CORRIDOR_COLLAPSE_TICKS, eating
		# the way out from the mouth so no slot can idle there forever.
		_corridor_collapse_ticks += 1
		var cfrac := clampf(float(_corridor_collapse_ticks)
			/ float(Terrain.CORRIDOR_COLLAPSE_TICKS), 0.0, 1.0)
		threshold = -int(round(float(terrain.corridor_collapse_len + 1) * cfrac))
	terrain.collapse_to(threshold)
	for c in terrain.just_voided:
		if _falling.size() >= MAX_FALLING:
			break
		var cx := c % terrain.w
		var cy := c / terrain.w
		_falling.append([terrain.origin + Vector2(float(cx), float(cy)) * CELL,
			0.0])

	# The route is LOCAL presentation: it lights the way home for this screen.
	var lp := player_pos[local_slot]
	var pc := terrain.cell_index(lp)
	if pc != _route_cell:
		_route_cell = pc
		_route = terrain.route_from(lp)

	# Lethal means lethal: no iframes, no mitigation. Armour does not help when
	# the floor is gone. Every LIVE slot is judged on its own ground — including
	# one still idling in the corridor when the collapse reaches it.
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.LIVE and not won \
				and terrain.is_void(player_pos[s]):
			_die(s)
	# Anything still out there goes with it.
	for i in range(enemies.count - 1, -1, -1):
		if terrain.is_void(enemies.pos[i]):
			# Reverse iteration does NOT make this tail-only: the predicate is
			# conditional, so a middle enemy in the void is despawned and the
			# tail swaps down over it. This site relocated nothing at all, which
			# during CLEARED — when a mini-boss can be mid-arrival — stranded
			# every parallel array.
			_relocate_enemy(i, enemies.count - 1)
			enemies.despawn(i)

## Blocks are only live while you are fighting. Not during the collapse: the walk
## to the gate is already the objective, and a second one competing with it makes
## both worse.
##
## The condition is phase ALONE. `paused`, `alive` and `won` do not belong in it
## — _physics_process returns before any step when any of those is set, so this
## function does not run at all then and a card screen simply freezes a live
## block where it stands. Naming them here would read as a despawn-on-pause rule
## that never fires.
func _step2e_blocks(dt: float) -> void:
	# A live block is HELD by the nearest LIVE slot; a block yet to spawn is
	# placed around the next slot in the cycle, so blocks appear across the
	# party rather than always beside slot zero.
	var anchor := _nearest_live(blocks.pos) if blocks.alive else _next_live_cycle()
	if anchor < 0:
		return
	if blocks.tick(dt, player_pos[anchor], phase == Phase.FIGHTING,
			Callable(terrain, "nearest_open"), _block_rng):
		_block_payout(_nearest_live(blocks.pos))

## What a completed hold pays, in priority order, to the HOLDER — the LIVE slot
## nearest the block when it completed.
func _block_payout(holder: int) -> void:
	if holder < 0:
		return
	var lo: Loadout = loadouts[holder]
	var matches := []
	for m in lo.matched_recipes():
		if lo.can_fuse(m[0], m[1].fused):
			matches.append(m)

	# The offer is SIMULATION state, entered unconditionally. It used to depend on
	# fusion_offered.get_connections() being non-empty, so a headless peer with no
	# UI and a peer with the screen open would diverge on whether the offer even
	# happened. Presentation OBSERVES the pending offer; it does not gate it, and
	# resolution is a deterministic input (auto-resolving on timeout), never a
	# live signal connection.
	if not matches.is_empty():
		# The fusion offer is a per-slot offer to the HOLDER, encoded as
		# (exploit index, recipe index) pairs.
		var pairs := PackedInt32Array()
		for m in matches:
			var ri := int(_recipe_index.get(m[1].fused.id, -1))
			if ri >= 0:
				pairs.append(int(m[0]))
				pairs.append(ri)
		if not pairs.is_empty():
			_open_offer(holder, OfferKind.FUSION, pairs)
			return

	var seed_m := _targeted_module(holder)
	if seed_m != null and _card_rng[holder].randf() < TARGETED_ODDS:
		_offer_cards(holder, CardMode.SEEDED, seed_m)
		return

	var roll: float = _card_rng[holder].randf()
	if roll < 0.40:
		salvage += 150 * subnet          # subnet starts at 1
		emit_signal("stats_changed")
	elif roll < 0.70:
		_block_heal(holder)
	else:
		_offer_cards(holder, CardMode.RANK_ONLY)

## The heal branch of a payout: heal the holder when they can use it, otherwise
## the value goes into the SHARED salvage pool so a full-health holder does not
## waste the block for the whole party. Returns true when a heal was applied.
func _block_heal(holder: int) -> bool:
	# player_health is the mutable pool; _eff_integrity() is the CAP it is
	# measured against. There is no `integrity` member.
	var cap := _eff_integrity(holder)
	if _is_live(holder) and player_health[holder] < cap:
		player_health[holder] = minf(cap, player_health[holder] + cap * 0.25)
		emit_signal("stats_changed")
		return true
	salvage += 150 * subnet
	emit_signal("stats_changed")
	return false

## The module that would do the most for the build right now: one that completes
## a recipe a row is a single module short of, or failing that one that fills a
## slot keeping a row inert. The near-miss search itself lives in RecipeTable —
## it is a question about recipes, and the arena has no business knowing a
## recipe's shape. This only filters by what is unlocked and placeable.
func _targeted_module(slot: int) -> Module:
	var mods := ModuleTable.by_id()
	var lo: Loadout = loadouts[slot]
	var unlocked := {}
	for m in _unlocked[slot]:
		unlocked[m.id] = true
	for ex in lo.exploits:
		var want := RecipeTable.near_miss(ex)
		if want == &"" or not unlocked.has(want):
			continue
		var cand: Module = mods[want]
		if not lo.legal_targets(cand).is_empty():
			return cand
	# Nothing is one short: fall back to anything that un-inerts a row.
	for ex in lo.exploits:
		if not ex.is_inert():
			continue
		var need := Module.Slot.VECTOR if ex.vector == null else Module.Slot.TRIGGER
		for m in _unlocked[slot]:
			if m.slot == need and not lo.legal_targets(m).is_empty():
				return m
	return null

## Crossing into the NEXT arena is the advance. The gate itself is just a mouth
## you walk through; touching it does nothing, which is the whole point of the
## rework — the transition is a walk, not a trigger.
##
## A HALF-PLANE crossing, not a distance or a rect. The plane is the next
## arena's edge, which is exactly where the corridor ends, so a long frame can
## carry the player past it but never over it.
##
## Strictly past, by half a unit, because the advance shuts the gate behind and
## a shut gate bars the whole corridor up to and including that plane — firing
## ON it sealed the player inside the block, where every axis of every step is
## refused and they stand in the doorway forever.
func _step2c_gate() -> void:
	if phase != Phase.CLEARED:
		return
	var g := terrain.gate()
	if g == null or not g.open:
		return
	# EVERY LIVE slot must be past the line. A slot that idles behind dies to
	# the corridor collapse, goes DEAD, and stops gating — so this cannot
	# deadlock, and the leash keeps a laggard within reach anyway.
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.LIVE \
				and (player_pos[s] - g.end).dot(g.dir) <= 0.5:
			return
	_advance_subnet()

func spawned_total() -> int:
	return _spawned_before + director.spawned

func _advance_subnet() -> void:
	blocks.reset()
	_spawned_before += director.spawned
	subnet += 1
	phase = Phase.FIGHTING
	collapse_left = 0.0
	_corridor_collapse_ticks = 0
	_route = PackedInt32Array()
	_route_cell = -1
	terrain.clear_temp_zones()
	_falling.clear()
	# Shards do NOT follow you. Arriving on a fresh subnet standing in the last
	# one's loose XP is both free levels and visually wrong.
	for i in range(shards.count - 1, -1, -1):
		shards.despawn(i)
	for i in range(enemies.count - 1, -1, -1):
		enemies.despawn(i)
	for i in range(projectiles.count - 1, -1, -1):
		projectiles.despawn(i)
	for i in range(hostiles.count - 1, -1, -1):
		hostiles.despawn(i)
	# Every LIVE slot is healed by the clear — a teammate who limped through the
	# gate is as cleared as the one who killed ICE.
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] != SlotState.LIVE:
			continue
		var cap := _eff_integrity(s)
		player_health[s] = minf(cap, player_health[s] + cap * SUBNET_CLEAR_HEAL)
	director.reset()
	_refresh_thresholds()
	# No teleport and no regeneration: the next arena was plotted before the
	# first frame and the player already walked into it. All that moves is which
	# arena the terrain calls current — and the gate, which shuts behind them.
	terrain.enter_next()
	emit_signal("stats_changed")

# ------------------------------------------------------------ progression ---

## XP to clear ONE level. Level 1 seeds `xp_needed` from the same function, so
## the first level costs what the curve says it costs rather than a literal that
## drifts out of step with it.
##
## 1.8, not the 1.0 this started at: a build now matures across a whole campaign
## rather than inside one five-minute subnet, so the curve has three times the
## wall-clock to spend itself over. It was briefly 2.4, which starved the build
## badly enough that the autopiloted run died in subnet 01 every time.
const XP_SLOWDOWN := 1.8

static func _xp_for(lvl: int) -> int:
	return int(round(float(5 + 3 * (lvl - 1)) * XP_SLOWDOWN))

func _gain_xp(n: int) -> void:
	xp += n
	feel.emit("pickup")
	while xp >= xp_needed:
		xp -= xp_needed
		level += 1
		feel.emit("level_up")
		# Was 20 + 12(n-1), taken from the spec. That curve assumed 10-14
		# kills/sec; the actual weapons produce ~0.5-4, so it stalled the run at
		# level 4. Measured against real play instead of derived from a rate.
		#
		# The x1.5 on top of that measured curve is a deliberate slowdown: at
		# 5 + 3(n-1) a good build was fully assembled inside the first minute,
		# which spent every card before the run had any difficulty to spend
		# them against.
		xp_needed = _xp_for(level)
		pending_levels += 1
		_fire_trigger(Module.TriggerKind.ON_LEVEL_UP)
	_settle_offers()
	emit_signal("stats_changed")

## The unlocked table, plus every fused module the loadout currently holds.
## Fused modules are never in ModuleTable — they enter the pool only by being
## owned, and legal_targets then offers the single slot holding one, as a
## rank-up. That is how a fused weapon climbs 1->5 like anything else.
func _card_pool(slot: int) -> Array:
	var lo: Loadout = loadouts[slot]
	var pool := []
	var seen := {}
	for m in _unlocked[slot]:
		var targets := lo.legal_targets(m)
		if targets.is_empty():
			continue          # nothing legal: not worth a card slot
		seen[m.id] = true
		pool.append([m, targets])
	for ex in lo.exploits:
		if not ex.head_is_fused() or seen.has(ex.vector.module.id):
			continue
		var ft := lo.legal_targets(ex.vector.module)
		if ft.is_empty():
			continue          # already at max rank
		seen[ex.vector.module.id] = true
		pool.append([ex.vector.module, ft])
	return pool

## The slot the open card or fusion offer belongs to — its pool, its RNG, and
## the loadout a choice lands in. Per-slot offer queues are a later task; this
## is the single open offer's owner.
# ------------------------------------------------------- offer machinery ---

## Encode a card as a table index: a module's index in the cached table, a
## fused module as FUSED_BASE - recipe index, the salvage card as -1.
func _encode_card(m: Module) -> int:
	if m == null:
		return -1
	if _module_index.has(m.id):
		return int(_module_index[m.id])
	if _recipe_index.has(m.id):
		return FUSED_BASE - int(_recipe_index[m.id])
	return -1

## The Module a card index names, or null for the salvage card or a bad index.
func _decode_card(code: int) -> Module:
	if code >= 0 and code < _modules.size():
		return _modules[code]
	if code <= FUSED_BASE:
		var ri := FUSED_BASE - code
		var recipes := RecipeTable.all()
		if ri >= 0 and ri < recipes.size():
			return recipes[ri].fused
	return null

## The index of a target in a legal_targets list, by FIELDS: the list is
## rebuilt on every query, so identity never matches. -1 when absent.
static func _target_index(targets: Array, t) -> int:
	if t == null:
		return -1
	for k in targets.size():
		var c = targets[k]
		if c.exploit == t.exploit and c.slot == t.slot and c.action == t.action:
			return k
	return -1

## Issue an offer to a slot: opened at once if the slot has none open, queued
## behind the open one otherwise. Sequence numbers are per slot and strictly
## increasing, so a choice can name exactly one offer.
func _open_offer(slot: int, kind: int, contents: PackedInt32Array) -> void:
	_offer_seq[slot] += 1
	var row := {"seq": _offer_seq[slot], "kind": kind, "contents": contents,
		"deadline": -1}
	if (_offer_open[slot] as Dictionary).is_empty():
		_open_now(slot, row)
	else:
		(_offer_queue[slot] as Array).append(row)
	_settle_offers()

## Make a row the slot's open offer, stamping the deadline from THIS tick.
func _open_now(slot: int, row: Dictionary) -> void:
	var timeout := int(_session.descriptor.get("choice_timeout", 0))
	row["deadline"] = (tick + timeout) if timeout > 0 else -1
	_offer_open[slot] = row
	paused = true
	if slot == local_slot:
		_emit_local_offer()

## Resolve the slot's open offer and open the next queued one, if any.
func _resolve_offer(slot: int) -> void:
	_offer_open[slot] = {}
	var q: Array = _offer_queue[slot]
	if not q.is_empty():
		_open_now(slot, q.pop_front())
	elif slot == local_slot:
		_emit_local_offer()
	_settle_offers()

## Apply a slot's choice record against its open offer. A record naming any
## other sequence, an out-of-range card, or an out-of-range target is NO
## choice: it is consumed and the offer stays open. A valid choice lands in the
## slot's own loadout and resolves the offer.
func _apply_choice(slot: int, card: int, target: int, offer: int) -> void:
	var open: Dictionary = _offer_open[slot]
	if open.is_empty() or offer != int(open["seq"]):
		return
	var contents: PackedInt32Array = open["contents"]
	if int(open["kind"]) == OfferKind.FUSION:
		if card == -2:
			salvage += 25
		elif card >= 0 and card * 2 + 1 < contents.size():
			var ex_i := contents[card * 2]
			var ri := contents[card * 2 + 1]
			var recipes := RecipeTable.all()
			if ri < 0 or ri >= recipes.size():
				return
			var lo: Loadout = loadouts[slot]
			if not lo.can_fuse(ex_i, recipes[ri].fused):
				return
			lo.fuse(ex_i, recipes[ri].fused)
			_recompile(slot)
		else:
			return
	else:
		if card == -2:
			salvage += 25
		elif card >= 0 and card < contents.size():
			var m := _decode_card(contents[card])
			if m == null:
				salvage += 50
			else:
				var targets := (loadouts[slot] as Loadout).legal_targets(m)
				if target < 0 or target >= targets.size():
					return
				var t = targets[target]
				(loadouts[slot] as Loadout).place_at(m, t.exploit, t.slot)
				_recompile(slot)
		else:
			return
	_resolve_offer(slot)
	emit_signal("stats_changed")

## Resolve a slot's open offer to its FIRST option: card zero into its first
## legal target, or the first fusion match. Used by deadlines and by slot exit.
func _apply_first(slot: int) -> void:
	var open: Dictionary = _offer_open[slot]
	if open.is_empty():
		return
	_apply_choice(slot, 0, 0, int(open["seq"]))
	# A first card with no legal target (an empty pool) is a decline.
	if not (_offer_open[slot] as Dictionary).is_empty() \
			and int(_offer_open[slot]["seq"]) == int(open["seq"]):
		_apply_choice(slot, -2, -1, int(open["seq"]))

## Any slot unresolved at its deadline takes its first option. Solo has no
## timeout; a session's is a descriptor parameter.
func _resolve_deadlines() -> void:
	for s in SessionRules.MAX_PLAYERS:
		var open: Dictionary = _offer_open[s]
		if open.is_empty():
			continue
		var dl := int(open["deadline"])
		if dl >= 0 and tick >= dl:
			_apply_first(s)

## A slot that dies or parks with offers pending resolves every one of them to
## its first option at once, so it can never hold a round open.
func _resolve_offer_on_slot_exit(slot: int) -> void:
	var guard := 0
	while not (_offer_open[slot] as Dictionary).is_empty() and guard < 64:
		_apply_first(slot)
		guard += 1
	(_offer_queue[slot] as Array).clear()
	_settle_offers()

## The round bookkeeping and the pause flag, from primitive state. A round is
## finished when no slot holds a LEVEL offer open or queued; then one owed
## level is spent and, if more are owed, the next round opens on this same
## tick. `paused` is simply "somebody has an offer open".
func _settle_offers() -> void:
	if _round_open and not _any_level_pending():
		_round_open = false
		pending_levels = maxi(0, pending_levels - 1)
	if pending_levels > 0 and not _round_open:
		_open_round()
	paused = _any_open_offer()

func _any_open_offer() -> bool:
	for s in SessionRules.MAX_PLAYERS:
		if not (_offer_open[s] as Dictionary).is_empty():
			return true
	return false

func _any_level_pending() -> bool:
	for s in SessionRules.MAX_PLAYERS:
		var open: Dictionary = _offer_open[s]
		if not open.is_empty() and int(open["kind"]) == OfferKind.LEVEL:
			return true
		for row in (_offer_queue[s] as Array):
			if int(row["kind"]) == OfferKind.LEVEL:
				return true
	return false

## Open a level-up ROUND: every LIVE slot is offered three cards from its own
## pool, shuffled by its own stream. With nobody LIVE the level stays owed.
func _open_round() -> void:
	var live := _live_slots()
	if live.is_empty():
		return
	_round_open = true
	for s in live:
		_open_offer(s, OfferKind.LEVEL, _card_contents(s, CardMode.NORMAL, null))

## Rebuild the local slot's presentation payloads from its open offer and emit
## the matching notice, so the overlay follows primitive state — after an open,
## a resolve, a restore or a rebind alike.
func _emit_local_offer() -> void:
	var open: Dictionary = _offer_open[local_slot]
	_pending_fusions = []
	if open.is_empty():
		emit_signal("offer_waiting", _unresolved_count())
		return
	var contents: PackedInt32Array = open["contents"]
	if int(open["kind"]) == OfferKind.FUSION:
		var recipes := RecipeTable.all()
		var matches := []
		var k := 0
		while k * 2 + 1 < contents.size():
			var ri := contents[k * 2 + 1]
			if ri >= 0 and ri < recipes.size():
				matches.append([contents[k * 2], recipes[ri]])
			k += 1
		_pending_fusions = matches
		emit_signal("fusion_offered", matches)
		return
	var cards := []
	var lo: Loadout = loadouts[local_slot]
	for code in contents:
		var m := _decode_card(code)
		cards.append([m, lo.legal_targets(m) if m != null else []])
	emit_signal("level_up_offered", cards)

## How many LIVE slots still hold an open offer — the "waiting for N" count.
func _unresolved_count() -> int:
	var n := 0
	for s in SessionRules.MAX_PLAYERS:
		if slot_state[s] == SlotState.LIVE \
				and not (_offer_open[s] as Dictionary).is_empty():
			n += 1
	return n

## Three cards for a slot, as encoded contents: its pool, filtered for a
## rank-only draw, shuffled by ITS stream, seeded module first if asked, padded
## with the salvage card.
func _card_contents(slot: int, mode: int, seed_module: Module) -> PackedInt32Array:
	var pool := _card_pool(slot)
	if mode == CardMode.RANK_ONLY:
		# Filter the TARGETS, not just the entries: a whole entry kept because
		# it contains a rank-up would leave its EMPTY_SLOT and REPLACE choices
		# on the card, so the screen would be a guaranteed-rank-AVAILABLE screen
		# rather than a guaranteed rank. An empty result falls through to the
		# ordinary pool on purpose — an ordinary draw beats an empty screen.
		var ranked := []
		for entry in pool:
			var only := []
			for t in entry[1]:
				if t.action == Loadout.Rule.RANK_UP:
					only.append(t)
			if not only.is_empty():
				ranked.append([entry[0], only])
		if not ranked.is_empty():
			pool = ranked
	# Seeded so a run reproduces exactly from a bug report, and from the OWNING
	# slot's stream so one player's card screen cannot perturb another's draws.
	for i in range(pool.size() - 1, 0, -1):
		var j: int = _card_rng[slot].randi_range(0, i)
		var tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp
	if mode == CardMode.SEEDED and seed_module != null:
		# Front of the deck, not an extra card: the screen still shows three.
		for i in pool.size():
			if pool[i][0] != null and pool[i][0].id == seed_module.id:
				var tmp2 = pool[0]; pool[0] = pool[i]; pool[i] = tmp2
				break
	var out := PackedInt32Array()
	for entry in pool:
		if out.size() >= 3:
			break
		out.append(_encode_card(entry[0]))
	while out.size() < 3:
		out.append(-1)                  # salvage card fallback
	return out

## Offer one slot a card draw of the given mode. Level-up ROUNDS go through
## _open_round; this is the per-slot path a block payout takes, and the one the
## suites drive directly.
func _offer_cards(slot: int, mode: int = CardMode.NORMAL,
		seed_module: Module = null) -> void:
	var kind := OfferKind.LEVEL
	if mode == CardMode.SEEDED:
		kind = OfferKind.SEEDED
	elif mode == CardMode.RANK_ONLY:
		kind = OfferKind.RANK_ONLY
	_open_offer(slot, kind, _card_contents(slot, mode, seed_module))

# --------------------------------------------- the local choice surface ---
#
# The UI calls these. None of them changes the simulation: each STAGES a
# choice record for the local slot's open offer, which the next submit carries
# into the ring and the tick applies when it executes. That is what makes a
# card pick a deterministic input rather than a callback.

func choose_card(m, target) -> void:
	var open: Dictionary = _offer_open[local_slot]
	if open.is_empty() or int(open["kind"]) == OfferKind.FUSION:
		return
	var contents: PackedInt32Array = open["contents"]
	var want := _encode_card(m)
	var card := -1
	for k in contents.size():
		if contents[k] == want:
			card = k
			break
	if card < 0:
		return
	var ti := -1
	if m != null:
		ti = _target_index((loadouts[local_slot] as Loadout).legal_targets(m), target)
		if ti < 0:
			return
	_local_choice = Vector3i(card, ti, int(open["seq"]))

func decline_card() -> void:
	var open: Dictionary = _offer_open[local_slot]
	if open.is_empty() or int(open["kind"]) == OfferKind.FUSION:
		return
	_local_choice = Vector3i(-2, -1, int(open["seq"]))

func choose_fusion(index: int) -> void:
	var open: Dictionary = _offer_open[local_slot]
	if open.is_empty() or int(open["kind"]) != OfferKind.FUSION:
		return
	_local_choice = Vector3i(index, -1, int(open["seq"]))

func decline_fusion() -> void:
	var open: Dictionary = _offer_open[local_slot]
	if open.is_empty() or int(open["kind"]) != OfferKind.FUSION:
		return
	_local_choice = Vector3i(-2, -1, int(open["seq"]))

func time_left() -> float:
	return maxf(0.0, SpawnDirector.SUBNET_SECONDS - director.elapsed)

# --------------------------------------------------------------- rendering ---

## Canvas order, low to high: the backdrop's ground at -10, this node's floor
## and effects at 0, then shards, enemies and botnet, then projectiles — and
## the Props layer above the lot. Everything an entity pool uses has to stay
## below PROPS_Z or walls stop occluding the swarm; test_draw_order pins it.
const PROPS_Z := 8

func _make_mm(size: float, z: int) -> MultiMeshInstance2D:
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_2D
	mm.use_colors = true
	mm.use_custom_data = true      # carries the glyph index
	mm.mesh = quad
	var node := MultiMeshInstance2D.new()
	node.multimesh = mm
	node.z_index = z
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/glyph.gdshader")
	node.material = mat
	add_child(node)
	return node

## Neon on black. Glow comes from WorldEnvironment with HDR 2D rather than a
## CanvasLayer shader — one full-screen pass cannot do a separable blur without
## a BackBufferCopy, and this path is both cheaper and idiomatic.
func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.016, 0.031, 0.027)
	env.glow_enabled = true
	env.glow_intensity = 1.6
	env.glow_bloom = 0.55
	env.glow_strength = 1.5
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	env.glow_hdr_threshold = 0.4
	for i in 4:
		env.set("glow_levels/%d" % (i + 2), 1.0)
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# The two canvases either side of everything else. Named, because "what
	# occludes what" is spread across four z_index numbers in three files and a
	# name is the only handle on it from outside.
	var grid_lines := Node2D.new()
	grid_lines.name = "Backdrop"
	grid_lines.set_script(load("res://scripts/run/backdrop.gd"))
	grid_lines.z_index = -10
	add_child(grid_lines)
	grid_lines.set("target", self)

	# Above every entity pool: walls, rails and gate posts are things you walk
	# BEHIND, and sharing this node's canvas drew them under the swarm.
	var props := Node2D.new()
	props.name = "Props"
	props.set_script(load("res://scripts/run/props.gd"))
	props.z_index = PROPS_Z
	add_child(props)
	props.set("target", self)

## Only enemies and projectiles need per-frame colour and glyph (the
## corruption lerp; a slot that is a packet, a mine or an orbiter). Shards and
## botnet nodes are one colour and one glyph for the life of the pool, and
## MultiMesh instance buffers persist — so those are written once here instead
## of ~4000 setter calls every frame.
func _prime_constant_instances(node: MultiMeshInstance2D, glyph: float, c: Color) -> void:
	var mm := node.multimesh
	for i in mm.instance_count:
		mm.set_instance_color(i, c)
		mm.set_instance_custom_data(i, Color(glyph, 0.0, 0.0, 0.0))

func _build_renderers() -> void:
	_mm_enemy = _make_mm(30.0, 2)
	_mm_enemy.multimesh.instance_count = MAX_ENEMIES
	_mm_proj = _make_mm(13.0, 3)
	_mm_proj.multimesh.instance_count = MAX_PROJECTILES
	_mm_shard = _make_mm(9.0, 1)
	_mm_shard.multimesh.instance_count = MAX_SHARDS
	_mm_botnet = _make_mm(26.0, 2)
	_mm_botnet.multimesh.instance_count = MAX_BOTNET

	_prime_constant_instances(_mm_shard, 5.0, Color(0.5, 1.3, 1.7))
	_prime_constant_instances(_mm_botnet, 3.0, Color(1.6, 0.5, 1.6))

func _update_renderers() -> void:
	var mm := _mm_enemy.multimesh
	mm.visible_instance_count = enemies.count
	# _depth_sort runs in the tick, not here: the order is a property of the
	# simulation step, and re-bucketing 600 entities per drawn frame would pay
	# for it 2.4x over on a 144 Hz display.
	#
	# The lerps below are inlined rather than routed through _rp — this is the
	# hot loop at the enemy cap, and a GDScript call per entity is not free.
	var ep := enemies.prev_pos
	var ec := enemies.pos
	for n in enemies.count:
		var i: int = _order[n]
		var t = enemy_types[enemies.type_index[i]]
		var s: float = 2.4 if enemies.type_index[i] == EnemyTable.ICE else 1.0
		# A submerged ambusher is out of the grid, so it cannot be hit and cannot
		# hurt you. Drawing it anyway would be the game lying about that.
		if _submerged[i] != 0:
			s = 0.0
		# _arriving is read HERE, separately: the union built in _step3_rebuild
		# is the grid's, and this site tests _submerged directly. Without its own
		# read the boss would draw at full size through the entire charge, before
		# the materialise ramp began.
		elif _arriving[i] > 0.0:
			if _arriving[i] > ARRIVAL_POP:
				s = 0.0
			else:
				# 0 -> full with a little overshoot, so it lands rather than
				# fades in.
				var k: float = 1.0 - _arriving[i] / ARRIVAL_POP
				s *= 1.0 + 0.35 * sin(k * PI) - (1.0 - k) * 0.15
				s *= k * (2.0 - k)
		mm.set_instance_transform_2d(n, Transform2D(0.0, Vector2(s, s), 0.0,
			to_iso(ep[i].lerp(ec[i], _alpha))))
		var frac: float = clampf(enemies.corruption[i] / maxf(thresholds[enemies.type_index[i]], 0.001), 0.0, 1.0)
		var shade := 1.15
		if _worm_id[i] != 0 and _worm_seg[i] != 0:
			shade = 1.15 * (0.82 - 0.07 * mini(_worm_seg[i], 4))
		# Flash composes ON TOP of the corruption tint rather than replacing it:
		# an enemy that is both nearly flipped and just hit is telling the
		# player two true things.
		var col: Color = t.color.lerp(Color(1.5, 0.25, 1.5), frac) * shade
		if _hit_flash[i] > 0.0:
			col = col.lerp(Color(2.4, 2.4, 2.4), _hit_flash[i] * 0.75)
		mm.set_instance_color(n, col)
		mm.set_instance_custom_data(n, Color(float(t.glyph), 0.0, 0.0, 0.0))
	mm = _mm_proj.multimesh
	mm.visible_instance_count = projectiles.count
	# Glyph and colour per frame: spawn happens inside the tick, which may not
	# touch a renderer node, and slots recycle, so a once-only stamp would need
	# per-instance memory. Bounded by MAX_PROJECTILES. A mine pulses, because
	# a mine you forgot you placed is a mine that kills you when the collapse
	# pushes you back over it.
	var beat := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
	for i in projectiles.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0,
			to_iso(_rp(projectiles, i))))
		var glyph := 14.0
		var col := Color(1.1, 1.7, 1.4)
		if _mine_left[i] > 0.0:
			glyph = 4.0
			col = Color(2.0, 1.1, 0.4).lerp(Color(2.2, 1.3, 0.5), beat)
		elif _orbit_left[i] > 0.0:
			glyph = 15.0
			col = Color(0.7, 2.0, 1.5)
		mm.set_instance_custom_data(i, Color(glyph, 0.0, 0.0, 0.0))
		mm.set_instance_color(i, col)
	mm = _mm_shard.multimesh
	mm.visible_instance_count = shards.count
	for i in shards.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0,
			to_iso(_rp(shards, i))))
	mm = _mm_botnet.multimesh
	mm.visible_instance_count = botnet.count
	for i in botnet.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0,
			to_iso(_rp(botnet, i))))

## Counting sort into screen-depth bands. O(n) with no comparisons, which is
## what makes per-entity depth ordering affordable at the enemy cap.
func _depth_sort() -> void:
	var n := enemies.count
	if n == 0:
		return
	for b in DEPTH_BANDS + 1:
		_band_count[b] = 0
	# Banded around the VIEW slot: draw order is a property of this screen,
	# and this screen may be looking through a teammate.
	var lp := player_pos[view_slot]
	var lo := lp.x + lp.y - 1800.0
	var span := 3600.0
	for i in n:
		var key := clampi(int((enemies.pos[i].x + enemies.pos[i].y - lo) / span * DEPTH_BANDS),
			0, DEPTH_BANDS - 1)
		_band_count[key] += 1
	var acc := 0
	for b in DEPTH_BANDS:
		var c := _band_count[b]
		_band_count[b] = acc
		acc += c
	for i in n:
		var key2 := clampi(int((enemies.pos[i].x + enemies.pos[i].y - lo) / span * DEPTH_BANDS),
			0, DEPTH_BANDS - 1)
		_order[_band_count[key2]] = i
		_band_count[key2] += 1

## One falling chunk of floor, as an extruded box.
##
## Same face convention as props.gd and backdrop.gd — near face at y = max, the
## darker turned-away face at x = max — because a chunk lit from a different sun
## than the ground it just left is the one thing that would break the illusion
## it exists to sell.
##
## `drop` is a SCREEN-space offset. The projection has no vertical axis, so
## falling is not a world-space move: it is the whole shape sliding down the
## screen, which is exactly how height is expressed everywhere else here.
func _draw_chunk(at: Vector2, drop: float, fade: float) -> void:
	var d := Vector2(0.0, drop)
	var up := Vector2(0.0, -FALL_HEIGHT)
	var g00 := to_iso(at) + d
	var g10 := to_iso(at + Vector2(CELL, 0.0)) + d
	var g11 := to_iso(at + Vector2(CELL, CELL)) + d
	var g01 := to_iso(at + Vector2(0.0, CELL)) + d
	# Reddened, because the arena is: these are pieces of the floor the player
	# has been watching go hot for the whole countdown.
	var top := Color(0.20, 0.09, 0.10, 0.85 * fade)
	var near := Color(0.13, 0.05, 0.06, 0.85 * fade)
	var side := Color(0.08, 0.03, 0.04, 0.85 * fade)
	var edge := Color(1.1, 0.30, 0.28, 0.75 * fade)
	draw_colored_polygon(PackedVector2Array([g01, g11, g11 + up, g01 + up]), near)
	draw_colored_polygon(PackedVector2Array([g10, g11, g11 + up, g10 + up]), side)
	draw_colored_polygon(PackedVector2Array([
		g00 + up, g10 + up, g11 + up, g01 + up]), top)
	draw_polyline(PackedVector2Array([
		g00 + up, g10 + up, g11 + up, g01 + up, g00 + up]), edge, 1.2)

## The world rectangle the camera can actually see, plus a margin.
##
## Everything below draws from map-sized data — terrain rects, voided row-runs,
## the route — and at five times the arena most of that is off-screen. Culling
## to this is the difference between drawing what the player can see and drawing
## the whole subnet every frame.
##
## Derived by unprojecting the viewport's half-diagonal: to_iso shears, so a
## screen rectangle is a rotated rectangle in world space, and its bounding box
## is what a cheap test needs.
func _visible_world_rect() -> Rect2:
	var vp := get_viewport_rect().size
	var half := from_iso(vp * 0.6).abs() + from_iso(Vector2(vp.x, -vp.y) * 0.6).abs()
	return Rect2(player_pos[view_slot] - half, half * 2.0)

## Ground the collapse has already taken, as horizontal RUNS of cells, clipped
## to the view.
##
## Runs, not cells: late in a collapse the arena is thousands of voided cells
## and one quad each is thousands of draw calls a frame. Merging each row's
## contiguous span turns a solid region into a handful of quads, and the region
## IS solid — the collapse eats by distance from the gate, so what it takes is
## contiguous almost everywhere.
func _void_runs(view: Rect2) -> Array:
	var out := []
	if terrain.voided.is_empty():
		return out
	var a := terrain.cell_xy(view.position)
	var b := terrain.cell_xy(view.end)
	var x0 := maxi(a.x, 0)
	var x1 := mini(b.x, terrain.w - 1)
	var y0 := maxi(a.y, 0)
	var y1 := mini(b.y, terrain.h - 1)
	for y in range(y0, y1 + 1):
		var row := y * terrain.w
		var run := -1
		# One past the end, so a run touching the right edge is still closed.
		for x in range(x0, x1 + 2):
			var on := x <= x1 and terrain.voided[row + x] != 0
			if on and run < 0:
				run = x
			elif not on and run >= 0:
				out.append(Vector3i(run, x - 1, y))
				run = -1
	return out

## The route home as world-space cell centres, culled to the view.
func _route_points(view: Rect2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for k in _route.size():
		var i := _route[k]
		var p := terrain.origin + Vector2(
			float(i % terrain.w) + 0.5, float(i / terrain.w) + 0.5) * Terrain.CELL
		if view.has_point(p):
			out.append(p)
	return out

## A cell-aligned world rect as its four projected corners. Under to_iso an AABB
## is a sheared parallelogram, never a rect.
func _ground_quad(a: Vector2, b: Vector2) -> PackedVector2Array:
	return PackedVector2Array([
		to_iso(a), to_iso(Vector2(b.x, a.y)), to_iso(b), to_iso(Vector2(a.x, b.y))])

func _draw() -> void:
	var view := _visible_world_rect()
	# Terrain first, so it sits under every entity.
	#
	# Drawn from `rects` rather than per-cell: the draw count is the number of
	# obstacles (a few dozen) rather than the number of solid cells (up to
	# eleven hundred). A world-space AABB under to_iso is a sheared
	# parallelogram, never a rect, so each is its four projected corners.
	# The whole arena reddens once it starts coming apart, so the change of state
	# is legible before the first tile actually goes.
	if phase == Phase.CLEARED:
		var heat := 1.0 - collapse_left / COLLAPSE_SECONDS
		var ar := terrain.arena()
		draw_colored_polygon(_ground_quad(ar.position, ar.end),
			Color(1.0, 0.15, 0.12, 0.05 + 0.17 * heat))

		# Ground that has already gone. Opaque, and nothing drawn on top of it:
		# it swallows the backdrop's lattice, and the lattice stopping IS the
		# edge of the world. An outline along each run's near edge was tried and
		# removed — the collapse frontier faces whichever way the gate does, so
		# lighting one side of it banded the interior into scanlines and marked
		# the wrong edge on three arenas out of four.
		for run in _void_runs(view):
			var a := terrain.origin + Vector2(float(run.x), float(run.z)) * CELL
			var b := terrain.origin + Vector2(float(run.y + 1), float(run.z + 1)) * CELL
			draw_colored_polygon(_ground_quad(a, b), Color(0.015, 0.008, 0.02))

		# The floor coming apart, as SOLID CHUNKS rather than squares blinking
		# out. Each voided cell falls away under gravity, tumbling out of the
		# world — which is what makes the arena read as a place with a
		# structure under it instead of a painted grid losing pixels.
		#
		# Drawn here, below the entity layer, because a chunk falling past the
		# player should go behind them.
		for fr in _falling:
			var ft: float = fr[1]
			var drop: float = 0.5 * FALL_GRAVITY * ft * ft
			var fade: float = clampf(1.0 - ft / FALL_LIFE, 0.0, 1.0)
			_draw_chunk(fr[0], drop, fade)

		# The way out, lit as TILES. A line from you to the gate is a claim the
		# geometry does not support — it points through walls. The gradient can
		# only ever tread on ground you can actually walk, and failing to reach
		# the gate now kills you, so this is the difference between a deadline
		# and an ambush.
		#
		# WHOLE cells, butted together. At two thirds of a cell they read as a
		# dotted line rather than a floor you follow, which at this alpha over a
		# reddened arena was very nearly nothing at all.
		var pulse := 0.75 + 0.25 * sin(Time.get_ticks_msec() * 0.005)
		var pts := _route_points(view)
		var half := Vector2(CELL, CELL) * 0.5
		for k in pts.size():
			# Brightest under your feet, fading toward the gate, so the wash
			# carries the direction of travel on its own.
			var f := 1.0 - float(k) / float(maxi(pts.size(), 1))
			draw_colored_polygon(_ground_quad(pts[k] - half, pts[k] + half),
				Color(0.35, 1.50, 1.00, (0.22 + 0.30 * f) * pulse))

	# Zones stay FLAT. They are conditions of the floor, not objects on it, and
	# giving them height would say you can stand behind one. Walls are objects
	# and are drawn by the Props layer, above every entity.
	for entry in terrain.rects:
		var tr: Rect2 = entry[0]
		var kind: int = entry[1]
		if kind == Terrain.Kind.WALL or not view.intersects(tr):
			continue
		var quad := PackedVector2Array([
			to_iso(tr.position), to_iso(Vector2(tr.end.x, tr.position.y)),
			to_iso(tr.end), to_iso(Vector2(tr.position.x, tr.end.y))])
		match kind:
			Terrain.Kind.HAZARD:
				draw_colored_polygon(quad, Color(1.0, 0.30, 0.28, 0.15))
			Terrain.Kind.SLOW:
				draw_colored_polygon(quad, Color(0.40, 0.60, 1.0, 0.13))
			Terrain.Kind.CORRUPTION:
				draw_colored_polygon(quad, Color(0.85, 0.35, 1.0, 0.15))

	# The walkway's FLOOR. Its rails and the gate's posts stand up, so they are
	# the Props layer's; this is the ground between them.
	#
	# Culled to the view rather than limited to the current subnet: the whole
	# campaign is one map, and the walkway you are standing in belongs to the
	# arena BEHIND you the moment you cross.
	for gi in terrain.gates.size():
		var g: Terrain.Gate = terrain.gates[gi]
		var along := Vector2(absf(g.dir.x), absf(g.dir.y))
		# Lapped one cell into the room at EACH end. The arena's own bright edge
		# runs right across the doorway otherwise, and a line across the mouth
		# reads as a barrier — which is the exact opposite of the point.
		var lap := along * Terrain.CELL
		var cr := Rect2(g.corridor.position - lap, g.corridor.size + lap * 2.0)
		if not view.intersects(cr):
			continue
		draw_colored_polygon(_ground_quad(cr.position, cr.end),
			Color(0.035, 0.085, 0.075))

	# Orbiter trails, drawn from RENDER positions so the arc and the glyph
	# agree at every frame fraction. Mines and orbiters themselves are glyphs
	# in the projectile multimesh (see _update_renderers).
	for i in projectiles.count:
		if _orbit_left[i] <= 0.0:
			continue
		var owner_slot := _owner_slot(_proj_owner[i])
		if owner_slot < 0:
			continue
		var centre := player_render_pos[owner_slot]
		var here := _rp(projectiles, i)
		var arm := here - centre
		var pts := PackedVector2Array()
		for k in 7:
			pts.append(to_iso(centre + arm.rotated(-0.09 * float(k))))
		draw_polyline(pts, Color(0.5, 1.6, 1.2, 0.35), 1.5)

	# Enemy fire. Distinct from the player's: red, and with a soft halo so a
	# shot crossing a busy field is still findable.
	for i in hostiles.count:
		var hpos := to_iso(_rp(hostiles, i))
		draw_circle(hpos, 7.0, Color(1.8, 0.45, 0.45, 0.22))
		draw_circle(hpos, 3.5, Color(1.9, 0.55, 0.5))

	# Telegraphs. A charger winding up and an ambusher surfacing are both about
	# to do something sudden, and both are only fair if you can see them coming.
	for i in enemies.count:
		var bh: int = enemy_types[enemies.type_index[i]].behaviour
		var tell := 0.0
		if bh == EnemyTable.Behaviour.CHARGER and _ai_phase[i] == CH_WINDUP:
			tell = 1.0 - _ai_timer[i] / CHARGE_WINDUP
		elif bh == EnemyTable.Behaviour.AMBUSHER and _ai_phase[i] == AM_SURFACING:
			tell = 1.0 - _ai_timer[i] / AMBUSH_SURFACING
		if tell <= 0.0:
			continue
		var ring := PackedVector2Array()
		for k in 17:
			var ta := TAU * k / 16.0
			ring.append(to_iso(_rp(enemies, i)
				+ Vector2(cos(ta), sin(ta)) * (14.0 + 26.0 * tell)))
		draw_polyline(ring, Color(1.9, 0.9, 0.4, 0.85 * (1.0 - tell)), 2.0)

	# Boss integrity, without a number and without a bar.
	#
	# Three channels at once, because any one of them alone is ambiguous at a
	# glance: the ring THINS as it drops, its colour walks from the type's own
	# toward a hot red, and it FRAGMENTS into fewer, shorter arcs. A healthy
	# boss wears a solid bright band; a nearly-dead one is a few dim red
	# scratches. Reading "it is coming apart" needs no calibration.
	for i in enemies.count:
		if _arriving[i] > 0.0 or _submerged[i] != 0:
			continue
		var ti2 := enemies.type_index[i]
		if ti2 != EnemyTable.ICE and not _is_miniboss(ti2):
			continue
		var frac2: float = clampf(
			enemies.integrity[i] / maxf(_spawn_hp[i], 0.001), 0.0, 1.0)
		var centre := to_iso(_rp(enemies, i))
		var rad2: float = (58.0 if ti2 == EnemyTable.ICE else 34.0)
		var width: float = 1.0 + 3.2 * frac2
		var col2: Color = enemy_types[ti2].color.lerp(
			Color(2.2, 0.30, 0.25), 1.0 - frac2)
		col2.a = 0.45 + 0.5 * frac2
		# Twelve arcs at full, three at death. Integer, so the fragmenting is a
		# visible step rather than a fade nobody registers.
		var arcs: int = maxi(3, int(round(12.0 * frac2)))
		var span: float = TAU / float(arcs) * (0.35 + 0.55 * frac2)
		for a4 in arcs:
			var base := TAU * float(a4) / float(arcs)
			var pts2 := PackedVector2Array()
			for stp in 5:
				var ang := base + span * float(stp) / 4.0
				pts2.append(centre + Vector2(cos(ang), sin(ang) * 0.5) * rad2)
			draw_polyline(pts2, col2, width)

	# Support links, and the ranged aim tell. Both are the same argument the
	# charger and ambusher telegraphs above already make: a thing that happens
	# to you with no warning reads as cheap, and the counterplay only exists if
	# the cue does.
	for i in enemies.count:
		if _arriving[i] > 0.0 or _submerged[i] != 0:
			continue
		var bh2: int = enemy_types[enemies.type_index[i]].behaviour
		if bh2 == EnemyTable.Behaviour.SUPPORT:
			if _ai_aim[i] != Vector2.ZERO:
				# Dashed rather than solid, so it reads as a beam being
				# maintained rather than as a wall.
				var a0 := to_iso(_rp(enemies, i))
				var b0 := to_iso(_ai_aim[i])
				var seg := 7
				for k2 in seg:
					if k2 % 2 == 1:
						continue
					var t0 := float(k2) / seg
					var t1 := float(k2 + 1) / seg
					draw_line(a0.lerp(b0, t0), a0.lerp(b0, t1),
						Color(0.5, 1.9, 1.0, 0.55), 1.5)
		elif bh2 == EnemyTable.Behaviour.RANGED:
			# The last fraction of the cooldown, so the tell is a wind-up and
			# not a permanent laser sight.
			var frac2: float = _ai_timer[i] / RANGED_COOLDOWN
			if frac2 > 0.0 and frac2 < 0.28:
				var k3: float = 1.0 - frac2 / 0.28
				var from2 := to_iso(_rp(enemies, i))
				# At the slot this enemy is actually hunting, not at whoever
				# holds this screen.
				var aim := _enemy_target[i] if i < _enemy_target.size() else -1
				if aim < 0 or aim >= SessionRules.MAX_PLAYERS or slot_state[aim] != SlotState.LIVE:
					aim = view_slot
				var to2 := to_iso(player_render_pos[aim])
				draw_line(from2, from2.lerp(to2, 0.35 + 0.5 * k3),
					Color(1.9, 0.5, 0.45, 0.30 + 0.45 * k3), 1.0 + k3)

	# Shot visuals, oldest fading out, one shape per kind. Drawn under the
	# ship. Fade is life / FX_LIFE clamped, so the longer-lived rings hold full
	# strength and then fade over their last FX_LIFE.
	for fx in _fx:
		var kind: int = fx[0]
		var at: Vector2 = fx[1]
		var dir: Vector2 = fx[2]
		var rad: float = fx[3]
		var f: float = clampf(fx[4] / FX_LIFE, 0.0, 1.0)
		var c: Color = fx[5]
		match kind:
			FxKind.RIPPLE:
				_draw_ring(at, rad * (1.0 - f * 0.25), Color(c.r, c.g, c.b, f * 0.85), 1.0 + 2.0 * f)
				_draw_ring(at, rad * (0.7 - f * 0.25), Color(c.r, c.g, c.b, f * 0.45), 1.0)
			FxKind.DASH:
				draw_line(to_iso(at + dir * 8.0), to_iso(at + dir * rad), Color(c.r, c.g, c.b, f), 1.0 + 3.0 * f)
			FxKind.BOLT:
				var pts := PackedVector2Array()
				var seg := 6
				var n := Vector2(-dir.y, dir.x).normalized()
				for k in seg + 1:
					var t := float(k) / float(seg)
					var jitter := sin(t * 11.0 + float(k) * 2.3) * 7.0 * (1.0 if k > 0 and k < seg else 0.0)
					pts.append(to_iso(at + dir * t + n * jitter))
				draw_polyline(pts, Color(c.r, c.g, c.b, f), 1.0 + 2.0 * f)
			FxKind.BEAM:
				var n2 := Vector2(-dir.y, dir.x)
				var w := BEAM_HALF_WIDTH * f
				var quad := PackedVector2Array([to_iso(at + n2 * w), to_iso(at + dir * rad + n2 * w),
					to_iso(at + dir * rad - n2 * w), to_iso(at - n2 * w)])
				draw_colored_polygon(quad, Color(c.r, c.g, c.b, 0.18 * f))
				draw_line(to_iso(at), to_iso(at + dir * rad), Color(c.r, c.g, c.b, f), 1.0 + 1.5 * f)
			FxKind.WEDGE:
				var pts2 := PackedVector2Array([to_iso(at)])
				for k in 13:
					var a := dir.angle() - CONE_HALF_ANGLE + 2.0 * CONE_HALF_ANGLE * float(k) / 12.0
					pts2.append(to_iso(at + Vector2(cos(a), sin(a)) * rad))
				draw_colored_polygon(pts2, Color(c.r, c.g, c.b, 0.22 * f))
			FxKind.PULSE:
				_draw_ring(at, rad * (1.0 - f * 0.25), Color(c.r, c.g, c.b, f * 0.85), 1.0 + 2.0 * f)
				for k in 8:
					var a2 := TAU * float(k) / 8.0
					var sp := Vector2(cos(a2), sin(a2))
					draw_line(to_iso(at + sp * rad * (0.55 - 0.3 * f)), to_iso(at + sp * rad * (0.85 - 0.3 * f)),
						Color(c.r, c.g, c.b, f * 0.7), 1.0)
			FxKind.BLAST:
				_draw_ring(at, rad * (1.0 - f * 0.25), Color(c.r, c.g, c.b, f * 0.85), 1.0 + 2.0 * f)
				for k in 10:
					var a3 := TAU * float(k) / 10.0 + 0.3
					var sp2 := Vector2(cos(a3), sin(a3))
					draw_line(to_iso(at + sp2 * rad * 0.3), to_iso(at + sp2 * rad * (0.5 + 0.5 * (1.0 - f))),
						Color(c.r, c.g, c.b, f * 0.6), 1.0)

	# Arrivals. Two phases: rings converging on the destination while glyph
	# columns rain down the isometric vertical, then a shockwave expanding out
	# of it as the body lands. Orange for a mini-boss, violet for ICE.
	for i in enemies.count:
		if _arriving[i] <= 0.0:
			continue
		var ai := to_iso(_rp(enemies, i))
		var is_ice := enemies.type_index[i] == EnemyTable.ICE
		var tint := Color(1.7, 0.5, 2.2) if is_ice else Color(2.0, 0.9, 0.35)
		if _arriving[i] > ARRIVAL_POP:
			# CHARGE. k runs 0 -> 1 across the phase.
			var k: float = 1.0 - (_arriving[i] - ARRIVAL_POP) / ARRIVAL_CHARGE
			var reach: float = 150.0 if is_ice else 100.0
			# The ground decal, growing. This is where it will land, and it is
			# legible for most of a second before anything can hurt you.
			draw_circle(ai, 6.0 + 26.0 * k,
				Color(tint.r, tint.g, tint.b, 0.10 + 0.20 * k))
			# Three rings converging inward, staggered.
			for ring in 3:
				var rk: float = clampf(k * 1.35 - ring * 0.16, 0.0, 1.0)
				if rk <= 0.0:
					continue
				var rad: float = reach * (1.0 - rk) + 12.0
				var pts := PackedVector2Array()
				for step in 25:
					var a2 := TAU * step / 24.0
					pts.append(ai + Vector2(cos(a2), sin(a2) * 0.5) * rad)
				draw_polyline(pts,
					Color(tint.r, tint.g, tint.b, 0.65 * rk), 1.0 + 1.5 * rk)
			# Glyph rain down the screen vertical, seeded off the slot so each
			# arrival looks different but is stable frame to frame.
			for col in 5:
				var ox: float = float((i * 7 + col * 13) % 11 - 5) * 9.0
				var fall: float = fmod(k * 2.2 + float(col) * 0.31, 1.0)
				var y0: float = -120.0 + fall * 120.0
				draw_line(ai + Vector2(ox, y0), ai + Vector2(ox, y0 + 16.0),
					Color(tint.r, tint.g, tint.b, 0.55 * (1.0 - fall)), 2.0)
		else:
			# POP. A shockwave out of the landing point.
			var pk: float = 1.0 - _arriving[i] / ARRIVAL_POP
			var sw := PackedVector2Array()
			var srad: float = 20.0 + 190.0 * pk
			for step2 in 33:
				var a3 := TAU * step2 / 32.0
				sw.append(ai + Vector2(cos(a3), sin(a3) * 0.5) * srad)
			draw_polyline(sw, Color(2.4, 2.3, 2.2, 0.9 * (1.0 - pk)),
				1.0 + 3.0 * (1.0 - pk))
			draw_circle(ai, 34.0 * (1.0 - pk),
				Color(2.4, 2.3, 2.2, 0.5 * (1.0 - pk)))

	# Damage numbers. ThemeDB.fallback_font ships with the engine and is not a
	# file in this repo, so the no-font-assets rule holds. Drawn in world space
	# under to_iso — they belong to an enemy at a place.
	if _numbers_pref and not feel.numbers.is_empty():
		var nf := ThemeDB.fallback_font
		for nrow in feel.numbers:
			var nf_a: float = clampf(nrow[3] / Feel.NUMBER_LIFE, 0.0, 1.0)
			var nc: Color = nrow[2]
			draw_string(nf, to_iso(nrow[0]), nrow[1],
				HORIZONTAL_ALIGNMENT_CENTER, -1, 13,
				Color(nc.r, nc.g, nc.b, nf_a))

	# The players, drawn screen-aligned at their projected positions: a glyph
	# that tilts with the ground plane reads as debris, not as the thing you
	# steer.
	#
	# A disc at PLAYER_RADIUS, so what you see is exactly what collides. The
	# facing tick on the rim shows where forward weapons fire — facing follows
	# the last non-zero movement.
	# Every LIVE slot is drawn, a teammate in its own hue under a name tag; an
	# ABSENT slot sits dimmed where it parked; a DEAD one is gone.
	var pf := ThemeDB.fallback_font
	for e in player_draw_list():
		var ps: int = e[0]
		var o := to_iso(player_render_pos[ps])
		var c: Color = e[1]
		var a: float = e[2]
		draw_circle(o, PLAYER_RADIUS, Color(c.r * 0.22, c.g * 0.22, c.b * 0.22, a))
		draw_arc(o, PLAYER_RADIUS, 0.0, TAU, 28, Color(c.r, c.g, c.b, a), 2.0)
		var tip := to_iso(player_render_pos[ps] + player_facing[ps] * (PLAYER_RADIUS + 9.0))
		var rim := to_iso(player_render_pos[ps] + player_facing[ps] * PLAYER_RADIUS)
		draw_line(rim, tip, Color(c.r, c.g, c.b, a), 2.0)
		var tag: String = e[3]
		if tag != "":
			draw_string(pf, o + Vector2(0.0, -PLAYER_RADIUS - 6.0), tag,
				HORIZONTAL_ALIGNMENT_CENTER, -1, 12, Color(c.r, c.g, c.b, a))

func _draw_ring(centre: Vector2, radius: float, colour: Color, width: float) -> void:
	var pts := PackedVector2Array()
	for k in 33:
		var a := TAU * k / 32.0
		pts.append(to_iso(centre + Vector2(cos(a), sin(a)) * radius))
	draw_polyline(pts, colour, width)

# ========================================================== state manifest ===
#
# ONE declaration of what the simulation IS, with explicit consumers. Every
# entry is [object_key, property, flags, slice_key, covers]:
#   object_key  which object holds it — see _manifest_object()
#   property    a var name, or "@name" for a DERIVED primitive built by
#               _derived_get / applied by _derived_set
#   flags       SNAPSHOT (serialize/restore visit it), HASH (_state_hash visits
#               it), VARLEN (a packed array whose length is not fixed)
#   slice_key   "" for the whole value, or a population key: the array is
#               sliced to that population's count for BOTH snapshot and hash,
#               never the full capacity — a restored peer's tails hold its own
#               pre-restore garbage
#   covers      the source vars a derived entry stands in for, so the
#               structural suite can prove every var is classified exactly once
#
# NOT_IN_MANIFEST names every var in the nine simulation files that is NOT
# carried, each with the rule that reconstructs it. test_manifest parses those
# files and fails on a var that is in neither list, or in both.
#
# Snapshots are PRIMITIVES ONLY and decode with bytes_to_var, never
# bytes_to_var_with_objects. restore_state is TRANSACTIONAL: it validates every
# field — type, fixed size, slice length, count range, enum value — before it
# writes a single one, and a payload past SNAPSHOT_MAX is refused before any
# allocation.

const SNAPSHOT := 1
const HASH := 2
const VARLEN := 4
const SH := SNAPSHOT | HASH

var STATE_FIELDS: Array = []
var NOT_IN_MANIFEST: Dictionary = {}

## Which source file each object key's vars live in, for the structural suite.
const MANIFEST_FILES := {
	"run": "run", "rng_sim": "run", "rng_block": "run",
	"rng_card0": "run", "rng_card1": "run", "rng_card2": "run", "rng_card3": "run",
	"enemies": "population", "projectiles": "population", "shards": "population",
	"botnet": "population", "hostiles": "population",
	"terrain": "terrain", "blocks": "blocks",
	"director": "director", "director_rng": "director",
	"flow0": "flow_field", "flow1": "flow_field", "flow2": "flow_field",
	"flow3": "flow_field", "lockstep": "lockstep",
}

func _build_manifest() -> void:
	var f: Array = []
	# --- populations: sliced to count -----------------------------------------
	for pk in ["enemies", "projectiles", "shards", "botnet", "hostiles"]:
		f.append([pk, "count", SH, "", []])
		f.append([pk, "_next_generation", SH, "", []])
		for prop in ["pos", "prev_pos", "vel", "force", "integrity", "corruption",
				"type_index", "radius", "generation", "state"]:
			f.append([pk, prop, SH, pk, []])
	# --- per-entity parallel arrays on the run --------------------------------
	for prop in ["_worm_id", "_worm_seg", "_spawn_hp", "_slow_left", "_slow_factor",
			"_knock", "_split_gen", "_rewarded", "_hit_flash", "_arriving",
			"_submerged", "_ai_phase", "_ai_timer", "_ai_aim"]:
		f.append(["run", prop, SH, "enemies", []])
	for prop in ["_proj_owner", "_proj_pierce", "_proj_last", "_proj_dist_left",
			"_proj_target", "_proj_target_gen", "_proj_reacquire", "_mine_left",
			"_orbit_left", "_orbit_phase"]:
		f.append(["run", prop, SH, "projectiles", []])
	for prop in ["_botnet_ratio", "_botnet_life"]:
		f.append(["run", prop, SH, "botnet", []])
	f.append(["run", "_hostile_life", SH, "hostiles", []])
	# --- worms, players, builds, offers --------------------------------------
	f.append(["run", "@worms", SH | VARLEN, "", ["_worm_trail", "_worm_cursor"]])
	f.append(["run", "_next_worm_id", SH, "", []])
	for prop in ["slot_state", "player_pos", "player_prev_pos", "player_vel",
			"player_facing", "player_health", "player_iframe", "player_shield",
			"_parked_health", "_low_armed", "_zone_slow_player", "kills", "flips",
			"inputs", "_offer_seq"]:
		f.append(["run", prop, SH, "", []])
	f.append(["run", "@loadouts", SH, "", ["loadouts"]])
	f.append(["run", "@offers", SH | VARLEN, "", ["_offer_open", "_offer_queue"]])
	f.append(["run", "@banked", SH, "", ["_banked"]])
	f.append(["run", "@trigger_fires", SH | VARLEN, "", ["_trigger_fires"]])
	for prop in ["_fire_acc", "_fire_cd", "_ward_left", "_shield_left"]:
		f.append(["run", prop, SH, "", []])
	# --- run scalars -----------------------------------------------------------
	for prop in ["tick", "level", "xp", "xp_needed", "pending_levels", "paused",
			"_round_open", "hitstop_ticks", "phase", "won", "subnet", "salvage",
			"_spawned_before", "collapse_left", "_corridor_collapse_ticks",
			"_steer_phase", "_cycle_cursor"]:
		f.append(["run", prop, SH, "", []])
	# --- terrain, blocks, director, flow fields, streams ----------------------
	f.append(["terrain", "current", SH, "", []])
	f.append(["terrain", "_collapse_idx", SH, "", []])
	f.append(["terrain", "@gate_open", SH, "", []])
	for prop in ["_tz_pos", "_tz_r2", "_tz_kind", "_tz_left"]:
		f.append(["terrain", prop, SH | VARLEN, "", []])
	for prop in ["alive", "pos", "progress", "elapsed", "next_at"]:
		f.append(["blocks", prop, SH, "", []])
	for prop in ["elapsed", "spawned", "dropped", "boss_spawned", "miniboss_fired"]:
		f.append(["director", prop, SH, "", []])
	f.append(["director", "@milli", SH | VARLEN, "", ["_milli"]])
	f.append(["director_rng", "state", SH, "", ["rng"]])
	for s in SessionRules.MAX_PLAYERS:
		var fk := "flow%d" % s
		f.append([fk, "_dist", SH | VARLEN, "", []])
		for prop in ["_ox", "_oy", "_centre", "_ready"]:
			f.append([fk, prop, SH, "", []])
	f.append(["rng_sim", "state", SH, "", ["_rng"]])
	f.append(["rng_block", "state", SH, "", ["_block_rng"]])
	for s in SessionRules.MAX_PLAYERS:
		f.append(["rng_card%d" % s, "state", SH, "", ["_card_rng"]])
	# --- the ring window: recovery continuity only, never hashed --------------
	f.append(["lockstep", "@ring", SNAPSHOT | VARLEN, "",
		["_moves", "_cards", "_targets", "_offers", "_tick_tag", "_have"]])
	STATE_FIELDS = f

	NOT_IN_MANIFEST = {
		"run": {
			"enemies": "container; its fields are listed by population key",
			"projectiles": "container", "shards": "container", "botnet": "container",
			"hostiles": "container", "grid": "container; rebuilt before first read",
			"terrain": "container", "blocks": "container", "queue": "container",
			"director": "container", "lockstep": "container",
			"_flow": "container; each field is listed under flowN",
			"_enemy_target": "scratch: decided in _behave before any read each tick",
			"_live_pos": "per-tick cache packed in _step2_integrate",
			"_live_of": "per-tick cache packed in _step2_integrate",
			"_execute_by_exploit": "derived: _rebuild_execute_table on recompile",
			"_execute_immune_type": "constant per enemy type",
			"_pending_fusions": "presentation: derived from _offer_open by _emit_local_offer",
			"_stalled_ticks": "transport liveness, local",
			"_local_choice": "local staged input, not yet a record",
			"_rec_moves": "take buffer", "_rec_cards": "take buffer",
			"_rec_targets": "take buffer", "_rec_offers": "take buffer",
			"_modules": "constant table cache", "_module_index": "constant",
			"_recipe_index": "constant",
			"_target_slot": "scratch: set at the top of _behave",
			"_hit_weight": "constant per enemy type",
			"_no_grid": "rebuilt whole in _step3_rebuild before the grid reads it",
			"_pending_splits": "filled and drained within one tick",
			"_fork_bomb_index": "constant", "_packet_filter_index": "constant",
			"player_render_pos": "presentation", "_alpha": "presentation",
			"_sheet": "derived from the descriptor counters",
			"alive": "derived: _any_live() after restore",
			"_route": "local presentation; recomputed from player_pos[local_slot]",
			"_route_cell": "local presentation; reset so the route recomputes",
			"feel": "presentation", "_shake_pref": "preference",
			"_numbers_pref": "preference", "_falling": "presentation",
			"_beam_hits": "beam selection scratch, presentation-free but never carried",
			"_beam_keys": "beam selection scratch",
			"_vignette": "presentation", "_fx": "presentation",
			"_order": "rebuilt whole in _depth_sort",
			"_band_count": "scratch for _depth_sort",
			"thresholds": "derived: _refresh_thresholds from subnet",
			"enemy_types": "constant", "resolved": "derived: _recompile on restore",
			"_buf": "scratch", "_counts": "scratch", "_pos_arrays": "scratch",
			"_skips": "scratch", "_unlocked": "derived from the descriptor counters",
			"input_override": "test seam", "external_drive": "test seam", "inputs": "",
			"_mm_enemy": "presentation", "_mm_proj": "presentation",
			"_mm_shard": "presentation", "_mm_botnet": "presentation",
			"_camera": "presentation", "_session": "immutable descriptor",
			"view_slot": "presentation: the slot this screen looks through",
			"_spectate": "presentation: the chosen spectate target",
			"_transport": "the network, polled above the guard; never simulation",
			"_pending_park": "host bookkeeping above the guard; the ABSENT tick it names is the state",
			"_pending_absent": "roster change keyed by tick, applied above the guard",
			"_pending_present": "roster change keyed by tick, applied above the guard; a returnee's buffered PRESENT",
			"_pending_hello": "host: reconnects awaiting a boundary; transport, never simulation",
			"_reconnect_attempts": "client link retry count; transport, never simulation",
			"_reconnect_frames": "client link retry frame count; transport, never simulation",
			"last_snapshot": "host: the bytes it last serialised; the wire, never simulation",
			"last_snapshot_tick": "host: the boundary of last_snapshot; the wire, never simulation",
			"local_slot": "this process's identity", "_players": "immutable roster size",
			"pickup_radius": "derived from the descriptor counters",
			"user_paused": "local overlay",
			"STATE_FIELDS": "the manifest itself", "NOT_IN_MANIFEST": "the manifest itself",
		},
		"population": {"capacity": "constant"},
		"terrain": {
			"origin": "immutable: Terrain.plan from the seed", "size": "immutable",
			"w": "immutable", "h": "immutable", "solid": "immutable: generate from the seed",
			"zone": "immutable", "rects": "immutable", "arenas": "immutable",
			"gates": "immutable layout; open flags carried by @gate_open",
			"_blocks": "derived from gate state: set_gate_open_flags rebuilds",
			"dist_from_gate": "derived: restore_collapse when CLEARED",
			"max_dist": "derived", "voided": "derived: restore_collapse voids the prefix",
			"_collapse_order": "derived", "_collapse_dist": "derived",
			"corridor_collapse_len": "derived",
			"just_voided": "filled and drained within one tick",
		},
		"blocks": {},
		"director": {"waves": "constant", "rate_mult": "derived from the immutable roster"},
		"flow_field": {},
		"grid": {
			"cell_size": "rebuilt before first read", "_cols": "rebuilt",
			"_rows": "rebuilt", "_ncells": "rebuilt", "_origin": "rebuilt",
			"_max_cols": "constant", "_max_rows": "constant", "_max_cells": "constant",
			"_cell_start": "rebuilt", "_cell_count": "rebuilt", "_cursor": "rebuilt",
			"_touched": "rebuilt", "_touched_n": "rebuilt", "_items": "rebuilt",
			"_item_pos": "rebuilt", "_item_mask": "rebuilt",
		},
		"hit_queue": {
			"kind": "begin_tick before first read", "source_exploit": "begin_tick",
			"target": "begin_tick", "target_generation": "begin_tick",
			"amount": "begin_tick", "count": "begin_tick",
			"dropped": "diagnostic counter, local", "_capacity": "constant",
			"drained_events": "per-tick diagnostic; never carried",
			"adjudication": "begin_tick", "outcome": "begin_tick",
			"killer_exploit": "begin_tick", "flipper_exploit": "begin_tick",
			"hit_exploit": "per pass", "hit_target": "per pass", "hit_count": "per pass",
			"execute_best": "per pass", "execute_by": "per pass",
		},
		"lockstep": {
			"executed": "set from the snapshot label: after_tick + 1",
			"delay": "immutable descriptor", "_required": "derived: _sync_ring_roster",
			"_present_mask": "derived: _sync_ring_roster",
			"_live_mask": "derived: _sync_ring_roster", "_players": "constant",
			"_checksums": "arrival state: peer reports, never simulation",
		},
	}
	# `inputs` IS carried; the empty reason above is a guard against listing it
	# twice by accident and is removed here.
	(NOT_IN_MANIFEST["run"] as Dictionary).erase("inputs")

func _manifest_object(key: String) -> Variant:
	match key:
		"run": return self
		"enemies": return enemies
		"projectiles": return projectiles
		"shards": return shards
		"botnet": return botnet
		"hostiles": return hostiles
		"terrain": return terrain
		"blocks": return blocks
		"director": return director
		"director_rng": return director.rng
		"lockstep": return lockstep
		"rng_sim": return _rng
		"rng_block": return _block_rng
	if key.begins_with("rng_card"):
		return _card_rng[int(key.substr(8))]
	if key.begins_with("flow"):
		return _flow[int(key.substr(4))]
	return null

func _population_of(key: String) -> Population:
	return _manifest_object(key) as Population

## The value an entry carries right now: the property, or the derived primitive,
## sliced to its population's count where the entry says so.
func _manifest_get(entry: Array) -> Variant:
	var obj = _manifest_object(entry[0])
	var prop: String = entry[1]
	var v = _derived_get(entry[0], prop) if prop.begins_with("@") else obj.get(prop)
	var slice_key: String = entry[3]
	if slice_key != "":
		var n := _population_of(slice_key).count
		v = v.slice(0, n)
	return v

# ------------------------------------------------------ derived primitives ---

func _derived_get(key: String, prop: String) -> Variant:
	match prop:
		"@worms":
			var ids := PackedInt32Array()
			for id in _worm_trail.keys():
				ids.append(int(id))
			ids.sort()
			var cursors := PackedInt32Array()
			var trails := PackedVector2Array()
			for id in ids:
				cursors.append(int(_worm_cursor[id]))
				trails.append_array(_worm_trail[id])
			return [ids, cursors, trails]
		"@loadouts":
			var stride := GID_STRIDE * Exploit.SLOT_COUNT
			var codes := PackedInt32Array(); codes.resize(SessionRules.MAX_PLAYERS * stride)
			codes.fill(-1)
			var ranks := PackedInt32Array(); ranks.resize(codes.size())
			var fused := PackedByteArray(); fused.resize(SessionRules.MAX_PLAYERS * GID_STRIDE)
			for s in SessionRules.MAX_PLAYERS:
				var lo: Loadout = loadouts[s]
				if lo == null:
					continue
				for e in mini(lo.exploits.size(), GID_STRIDE):
					var ex: Exploit = lo.exploits[e]
					fused[s * GID_STRIDE + e] = 1 if ex.head_is_fused() else 0
					for si in Exploit.SLOT_COUNT:
						var em: EquippedModule = ex.at(si)
						if em == null:
							continue
						var k := s * stride + e * Exploit.SLOT_COUNT + si
						codes[k] = _encode_card(em.module)
						ranks[k] = int(em.rank)
			return [codes, ranks, fused]
		"@offers":
			var n := SessionRules.MAX_PLAYERS
			var oseq := PackedInt32Array(); oseq.resize(n)
			var okind := PackedInt32Array(); okind.resize(n); okind.fill(-1)
			var odl := PackedInt32Array(); odl.resize(n)
			var olen := PackedInt32Array(); olen.resize(n)
			var oflat := PackedInt32Array()
			var qslot := PackedInt32Array()
			var qseq := PackedInt32Array()
			var qkind := PackedInt32Array()
			var qlen := PackedInt32Array()
			var qflat := PackedInt32Array()
			for s in n:
				var open: Dictionary = _offer_open[s]
				if not open.is_empty():
					oseq[s] = int(open["seq"]); okind[s] = int(open["kind"])
					odl[s] = int(open["deadline"])
					var c: PackedInt32Array = open["contents"]
					olen[s] = c.size(); oflat.append_array(c)
				for row in (_offer_queue[s] as Array):
					qslot.append(s); qseq.append(int(row["seq"]))
					qkind.append(int(row["kind"]))
					var qc: PackedInt32Array = row["contents"]
					qlen.append(qc.size()); qflat.append_array(qc)
			return [oseq, okind, odl, olen, oflat, qslot, qseq, qkind, qlen, qflat]
		"@banked":
			var n := SessionRules.MAX_PLAYERS
			var bs := PackedInt32Array(); bs.resize(n)
			var bk := PackedInt32Array(); bk.resize(n)
			var bf := PackedInt32Array(); bf.resize(n)
			for s in n:
				var b: Dictionary = _banked[s]
				bs[s] = int(b[&"salvage"]); bk[s] = int(b[&"kills"]); bf[s] = int(b[&"flips"])
			return [bs, bk, bf]
		"@trigger_fires":
			var keys := PackedInt32Array()
			for k in _trigger_fires.keys():
				keys.append(int(k))
			keys.sort()
			var vals := PackedInt32Array()
			for k in keys:
				vals.append(int(_trigger_fires[k]))
			return [keys, vals]
		"@gate_open":
			return terrain.gate_open_flags()
		"@milli":
			var out := PackedInt32Array()
			for m in director._milli:
				out.append(int(m))
			return out
		"@ring":
			return lockstep.snapshot_window(tick)
	return null

func _derived_set(key: String, prop: String, v) -> void:
	match prop:
		"@worms":
			_worm_trail.clear()
			_worm_cursor.clear()
			var ids: PackedInt32Array = v[0]
			var cursors: PackedInt32Array = v[1]
			var trails: PackedVector2Array = v[2]
			for k in ids.size():
				_worm_cursor[ids[k]] = cursors[k]
				_worm_trail[ids[k]] = trails.slice(k * WORM_TRAIL_LEN, (k + 1) * WORM_TRAIL_LEN)
		"@loadouts":
			var stride := GID_STRIDE * Exploit.SLOT_COUNT
			var codes: PackedInt32Array = v[0]
			var ranks: PackedInt32Array = v[1]
			for s in SessionRules.MAX_PLAYERS:
				var lo: Loadout = loadouts[s]
				if lo == null:
					continue
				var exploits := []
				var last := -1
				for e in GID_STRIDE:
					var ex := Exploit.new()
					var any := false
					for si in Exploit.SLOT_COUNT:
						var k := s * stride + e * Exploit.SLOT_COUNT + si
						var m := _decode_card(codes[k])
						if m == null:
							continue
						var em := EquippedModule.new(m)
						em.rank = ranks[k]
						ex.set_at(si, em)
						any = true
					exploits.append(ex)
					if any:
						last = e
				lo.exploits = exploits.slice(0, last + 1)
		"@offers":
			var n := SessionRules.MAX_PLAYERS
			var oseq: PackedInt32Array = v[0]; var okind: PackedInt32Array = v[1]
			var odl: PackedInt32Array = v[2]; var olen: PackedInt32Array = v[3]
			var oflat: PackedInt32Array = v[4]
			var qslot: PackedInt32Array = v[5]; var qseq: PackedInt32Array = v[6]
			var qkind: PackedInt32Array = v[7]; var qlen: PackedInt32Array = v[8]
			var qflat: PackedInt32Array = v[9]
			var at := 0
			for s in n:
				_offer_queue[s] = []
				if okind[s] < 0:
					_offer_open[s] = {}
				else:
					_offer_open[s] = {"seq": oseq[s], "kind": okind[s],
						"contents": oflat.slice(at, at + olen[s]), "deadline": odl[s]}
				at += olen[s]
			var qat := 0
			for k in qslot.size():
				(_offer_queue[qslot[k]] as Array).append({"seq": qseq[k],
					"kind": qkind[k], "contents": qflat.slice(qat, qat + qlen[k]),
					"deadline": -1})
				qat += qlen[k]
		"@banked":
			for s in SessionRules.MAX_PLAYERS:
				_banked[s] = {&"salvage": v[0][s], &"kills": v[1][s], &"flips": v[2][s]}
		"@trigger_fires":
			_trigger_fires.clear()
			var keys: PackedInt32Array = v[0]
			var vals: PackedInt32Array = v[1]
			for k in keys.size():
				_trigger_fires[keys[k]] = vals[k]
		"@gate_open":
			terrain.set_gate_open_flags(v)
		"@milli":
			var out := []
			for m in v:
				out.append(int(m))
			director._milli = out
		"@ring":
			pass    # merged in _after_restore, once executed is set

## Shape-check a derived value against what this run would produce, so a
## hostile payload cannot smuggle a wrong type or an inconsistent pair of
## parallel arrays into the apply pass.
func _derived_valid(prop: String, v) -> bool:
	var cur: Variant = _derived_get("", prop)
	if prop == "@gate_open" or prop == "@milli":
		return typeof(v) == typeof(cur) and (prop == "@milli" or v.size() == cur.size())
	if prop == "@ring":
		return typeof(v) == TYPE_DICTIONARY
	if typeof(v) != TYPE_ARRAY or v.size() != cur.size():
		return false
	for k in v.size():
		if typeof(v[k]) != typeof(cur[k]):
			return false
	match prop:
		"@worms":
			return v[0].size() == v[1].size() \
				and v[2].size() == v[0].size() * WORM_TRAIL_LEN
		"@loadouts":
			if v[0].size() != cur[0].size() or v[1].size() != cur[1].size() \
					or v[2].size() != cur[2].size():
				return false
			for r in v[1]:
				if r < 0 or r > 99:
					return false
			return true
		"@offers":
			var n := SessionRules.MAX_PLAYERS
			for i in 4:
				if v[i].size() != n:
					return false
			var total := 0
			for s in n:
				if v[1][s] < -1 or v[1][s] >= OfferKind.size() or v[3][s] < 0:
					return false
				total += v[3][s]
			if v[4].size() != total:
				return false
			var qn: int = v[5].size()
			if v[6].size() != qn or v[7].size() != qn or v[8].size() != qn:
				return false
			var qtotal := 0
			for k in qn:
				if v[5][k] < 0 or v[5][k] >= n or v[7][k] < 0 \
						or v[7][k] >= OfferKind.size() or v[8][k] < 0:
					return false
				qtotal += v[8][k]
			return v[9].size() == qtotal
		"@banked":
			return v[0].size() == SessionRules.MAX_PLAYERS \
				and v[1].size() == v[0].size() and v[2].size() == v[0].size()
		"@trigger_fires":
			return v[0].size() == v[1].size()
	return true

# ------------------------------------------------------- hash / snapshot ---

## A checksum of executed simulation state: every HASH entry, sliced to its
## live prefix, in manifest order, hashed by its raw bytes. Arrival state (the
## ring) is excluded, so two peers with identical simulations but different
## in-flight records agree.
func _state_hash() -> int:
	var vals := []
	for entry in STATE_FIELDS:
		if (int(entry[2]) & HASH) == 0:
			continue
		vals.append(_manifest_get(entry))
	return hash(var_to_bytes(vals))

## The whole SNAPSHOT-flagged manifest, labelled with the tick whose record was
## applied last, as primitives. Carries the ring's (tick, tick + delay] window
## so the restoring peer resumes at tick + 1 with every record it needs.
func serialize_state(after_tick: int) -> PackedByteArray:
	var fields := []
	for entry in STATE_FIELDS:
		if (int(entry[2]) & SNAPSHOT) == 0:
			continue
		if entry[1] == "@ring":
			fields.append(lockstep.snapshot_window(after_tick))
		else:
			fields.append(_manifest_get(entry))
	return var_to_bytes({"v": SessionRules.SNAPSHOT_VERSION, "tick": after_tick,
		"fields": fields})

## Restore from a peer's bytes. Everything is validated into a pending list
## FIRST — root shape, version, label, field count, each field's type and
## size, every population count against its capacity, every sliced array
## against its count, every enum — and only then written. On any violation the
## live run is untouched and false is returned. Derived state is rebuilt after
## the write: builds recompiled, terrain blockers and collapse re-derived, the
## ring merged without overwriting delivered records, the local offer re-emitted.
func restore_state(bytes: PackedByteArray, after_tick: int) -> bool:
	if bytes.size() > SessionRules.SNAPSHOT_MAX or bytes.is_empty():
		return false
	var raw = bytes_to_var(bytes)
	if typeof(raw) != TYPE_DICTIONARY:
		return false
	if int(_num(raw.get("v", -1))) != SessionRules.SNAPSHOT_VERSION:
		return false
	if int(_num(raw.get("tick", -1))) != after_tick:
		return false
	var fields = raw.get("fields", null)
	if typeof(fields) != TYPE_ARRAY:
		return false
	var entries := []
	for entry in STATE_FIELDS:
		if (int(entry[2]) & SNAPSHOT) != 0:
			entries.append(entry)
	if fields.size() != entries.size():
		return false
	# Pass 1: population counts, which every sliced length is checked against.
	var counts := {}
	for k in entries.size():
		var e: Array = entries[k]
		if e[1] == "count" and MANIFEST_FILES.get(e[0], "") == "population":
			var v = fields[k]
			if typeof(v) != TYPE_INT:
				return false
			var cap: int = _population_of(e[0]).capacity
			if v < 0 or v > cap:
				return false
			counts[e[0]] = v
	# Pass 2: every field's shape and value.
	for k in entries.size():
		var e: Array = entries[k]
		var prop: String = e[1]
		var v = fields[k]
		if prop.begins_with("@"):
			if not _derived_valid(prop, v):
				return false
			continue
		var cur: Variant = _manifest_object(e[0]).get(prop)
		if typeof(v) != typeof(cur):
			return false
		var slice_key: String = e[3]
		if slice_key != "":
			if v.size() != int(counts[slice_key]):
				return false
		elif _is_packed(v) and (int(e[2]) & VARLEN) == 0 and v.size() != cur.size():
			return false
		if not _valid_value(e[0], prop, v):
			return false
	# Pass 3: write. Nothing above mutated the run.
	for k in entries.size():
		var e: Array = entries[k]
		var prop: String = e[1]
		var v = fields[k]
		if prop.begins_with("@"):
			_derived_set(e[0], prop, v)
			continue
		var obj = _manifest_object(e[0])
		var slice_key: String = e[3]
		if slice_key != "":
			var arr = obj.get(prop)
			for i in v.size():
				arr[i] = v[i]
			obj.set(prop, arr)
		else:
			obj.set(prop, v)
	_after_restore(after_tick, raw)
	return true

static func _num(v) -> float:
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return -1.0
	var f := float(v)
	return f if is_finite(f) else -1.0

static func _is_packed(v) -> bool:
	var t := typeof(v)
	return t == TYPE_PACKED_BYTE_ARRAY or t == TYPE_PACKED_INT32_ARRAY \
		or t == TYPE_PACKED_INT64_ARRAY or t == TYPE_PACKED_FLOAT32_ARRAY \
		or t == TYPE_PACKED_FLOAT64_ARRAY or t == TYPE_PACKED_VECTOR2_ARRAY

## Enum and range rules for the fields that have them. Anything a later step
## indexes with must be in range HERE, or a hostile count becomes a crash.
func _valid_value(key: String, prop: String, v) -> bool:
	var file: String = MANIFEST_FILES.get(key, "")
	if file == "population":
		match prop:
			"state":
				for b in v:
					if b > Population.FLIPPED:
						return false
			"type_index":
				if key == "enemies":
					for t in v:
						if t < 0 or t >= enemy_types.size():
							return false
			"_next_generation":
				return v >= 1
		return true
	if key == "run":
		match prop:
			"slot_state":
				for b in v:
					if b > SlotState.ABSENT:
						return false
			"phase":
				return v >= Phase.FIGHTING and v <= Phase.CLEARED
			"subnet":
				return v >= 1 and v <= SpawnDirector.CAMPAIGN_SUBNETS
			"level":
				return v >= 1
			"tick":
				return v >= 0
			"_worm_id":
				for w in v:
					if w < 0:
						return false
	if key == "terrain":
		match prop:
			"current":
				return v >= 0 and v < terrain.arenas.size()
			"_collapse_idx":
				return v >= 0
			"_tz_pos", "_tz_r2", "_tz_kind", "_tz_left":
				return v.size() <= Terrain.MAX_TEMP_ZONES
	if key.begins_with("flow") and prop == "_dist":
		return v.size() == 0 or v.size() == FlowField.SIDE * FlowField.SIDE
	return true

## Rebuild everything the manifest deliberately does not carry, in dependency
## order, and re-arm the ring at the tick after the snapshot.
func _after_restore(after_tick: int, raw: Dictionary) -> void:
	tick = after_tick
	lockstep.executed = after_tick + 1
	_sync_ring_roster()
	# Merge the carried window; records already delivered here are kept.
	var entries := []
	for entry in STATE_FIELDS:
		if (int(entry[2]) & SNAPSHOT) != 0:
			entries.append(entry)
	for k in entries.size():
		if entries[k][1] == "@ring":
			lockstep.merge_window(raw["fields"][k], after_tick)
	_recompile()
	_refresh_thresholds()
	# Temp zones' parallel arrays must agree; a bad payload passed the length
	# rule per array, so trim to the shortest rather than index past one.
	var tzn: int = mini(mini(terrain._tz_pos.size(), terrain._tz_r2.size()),
		mini(terrain._tz_kind.size(), terrain._tz_left.size()))
	terrain._tz_pos.resize(tzn); terrain._tz_r2.resize(tzn)
	terrain._tz_kind.resize(tzn); terrain._tz_left.resize(tzn)
	if phase == Phase.CLEARED:
		terrain.restore_collapse(terrain._collapse_idx)
	else:
		terrain._clear_collapse_state()
	_route = PackedInt32Array()
	_route_cell = -1
	_pending_splits.clear()
	_enemy_target.fill(-1)
	_refresh_live_cache()
	alive = _any_live()
	# The restored world's verdict replaces this peer's own: a false ending is
	# gone, and a peer repaired INTO the host's terminal state now holds the
	# same candidate, so the next check can agree. Nothing is emitted — only
	# END ends a session.
	if won:
		_session.end_outcome = NetworkSession.Outcome.WIN
	elif not alive:
		_session.end_outcome = NetworkSession.Outcome.LOSS
	else:
		_session.end_outcome = NetworkSession.Outcome.NONE
	_emit_local_offer()
	emit_signal("stats_changed")
