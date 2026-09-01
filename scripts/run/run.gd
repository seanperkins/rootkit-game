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
const CHARGE_DASH := 0.5
const CHARGE_RECOVER := 0.8
const CHARGE_SPEED := 3.0

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

## The player's actual velocity, derived from the step TAKEN rather than the
## step requested — so it accounts for the arena clamp and for wall slides,
## which is exactly what a flanker needs to aim at.
var player_vel := Vector2.ZERO

## Per-enemy AI memory. Sized MAX_ENEMIES and reset on every spawn, because
## Population.spawn recycles slots and a stale phase is a live bug — an enemy
## that inherits a mid-dash timer commits to a dash it never wound up for.
var _ai_phase: PackedInt32Array
var _ai_timer: PackedFloat32Array
var _ai_aim: PackedVector2Array
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

var _pending_fusions: Array = []
## Out of the entity grid, and therefore untouchable and harmless.
## How lit each enemy is from a hit landed this tick, decayed in _age_fx and
## read by the renderer. Per-enemy, so it needs BOTH halves of the slot
## invariant: zeroed on spawn AND relocated on despawn.
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
## affects the player without a second timer: standing in it IS the duration.
var _zone_slow_player := false

## An absorb pool granted in whole chunks when a shielding exploit fires.
##
## NOT integrity: it does not heal, it does not appear in the integrity ratio,
## and it is spent before armour and defence are ever consulted — a shield is
## something in the way, not toughness.
var player_shield := 0.0

## ON_LOW_INTEGRITY fires on the CROSSING, not while below the line. Without the
## latch it fires every tick spent under 40%, which is a DPS cliff and, on a
## defensive vector, an infinite shield.
var _low_armed := true
var queue: HitQueue
var loadout: Loadout
var director: SpawnDirector

var player_pos := Vector2.ZERO
## The merged base + meta player sheet. Seeded in _ready, because a declaration
## initialiser is evaluated before _ready reads the save — a player with memory
## ranks would otherwise start every run at the base 100.
var _sheet: Dictionary = PlayerStats.BASE.duplicate()
var player_health := 0.0
var player_iframe := 0.0
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
var _route: PackedInt32Array = PackedInt32Array()
var _route_cell := -1
## director.spawned is per-SUBNET, because director.reset() zeroes it on every
## advance. The campaign total has to survive that.
var _spawned_before := 0

## Banking is INCREMENTAL now a run spans several subnets. SaveGame.bank()
## ACCUMULATES into the save, so handing it the running totals at every subnet
## clear would count subnet 01's kills three times over and hand out unlock
## milestones nobody earned.
var _banked := {&"salvage": 0, &"kills": 0, &"flips": 0}

var level := 1
var xp := 0
var xp_needed := _xp_for(1)
var salvage := 0
var kills := 0
var flips := 0
var pending_levels := 0
var paused := false
## The PLAYER's pause, kept separate from `paused` on purpose. `paused` means
## "a modal offer is open" and four sites clear it unconditionally
## (choose_fusion, decline_fusion, choose_card, decline_card); sharing one bool
## would let a card decline release a pause it never took, and ui.gd's
## `not run.paused` force-hide would then strand a pending fusion.
var user_paused := false
var pickup_radius := 0.0
## Presentation state. Pure, and deliberately not part of any simulation step.
var feel := Feel.new()
## Player preference, applied to the composed shake offset. Zero is a supported
## value: screen shake is one of the two effects here that can make a game
## unplayable rather than merely annoying. Loaded from prefs in _ready.
var _shake_pref := 1.0
## Whether floating damage numbers are drawn. Also a preference.
var _numbers_pref := true
## Screen-edge damage flash, 1.0 at the moment of the hit. Read by ui.gd. This
## is the shake-INDEPENDENT damage tell, which is what makes shake = 0 a
## supported setting rather than a way to lose information.
var _vignette := 0.0
## Longest unscaled delta the presentation half will honour. Unclamped, a first
## frame, a scene load or an OS suspend would expire every live effect in one
## step.
const MAX_PRESENT_DT := 0.1
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
var _fire_cd: PackedFloat32Array
## Transient shot visuals. BROADCAST, BEAM and CHAIN resolve straight through
## the hit queue and drew nothing at all — you saw enemies die with no sign of
## what killed them. Bounded by the fire budget: 3 exploits x 4 fires x FX_LIFE
## worth of ticks.
const FX_LIFE := 0.13
## Hit flash fades in about a sixth of a second — long enough to read at 60fps,
## short enough that a swarm under fire is not a white blob.
const HIT_FLASH_DECAY := 6.0

## A boss entrance, in two phases. The charge is long enough to read and move
## out of; the pop is short enough to feel like an impact rather than a fade.
## Not interruptible and not skippable — an arrival you can shoot through is not
## an entrance.
const ARRIVAL_CHARGE := 0.9
const ARRIVAL_POP := 0.25
const ARRIVAL_TOTAL := ARRIVAL_CHARGE + ARRIVAL_POP
var _fx_line: Array = []      # [a, b, t, colour]
var _fx_ring: Array = []      # [centre, radius, t, colour]
var _order: PackedInt32Array
var _band_count: PackedInt32Array
const DEPTH_BANDS := 192

var thresholds: PackedFloat32Array
var enemy_types: Array
var resolved: Array = []
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
var _unlocked: Array = []
## Headless tests drive the player through this instead of the keyboard.
var input_override = null
var _rng := RandomNumberGenerator.new()
var _card_rng := RandomNumberGenerator.new()

var _mm_enemy: MultiMeshInstance2D
var _mm_proj: MultiMeshInstance2D
var _mm_shard: MultiMeshInstance2D
var _mm_botnet: MultiMeshInstance2D
var _camera: Camera2D

func _ready() -> void:
	_rng.seed = 20260830
	_card_rng.seed = 20260830
	_block_rng.seed = 20260831
	enemy_types = EnemyTable.all()
	thresholds = PackedFloat32Array()
	thresholds.resize(enemy_types.size())
	_refresh_thresholds()
	for i in enemy_types.size():
		thresholds[i] = enemy_types[i].corruption_threshold

	# A fixed window that follows the player, NOT the arena. See Grid._init:
	# every query in this game is near the player, so indexing the whole map
	# spends per-tick work on ground nobody is standing on.
	grid = Grid.new(Vector2.ZERO, Vector2(GRID_WINDOW, GRID_WINDOW), CELL,
		MAX_ENEMIES + MAX_PROJECTILES + MAX_SHARDS + MAX_BOTNET + 1)
	enemies = Population.new(MAX_ENEMIES)
	projectiles = Population.new(MAX_PROJECTILES)
	shards = Population.new(MAX_SHARDS)
	botnet = Population.new(MAX_BOTNET)
	hostiles = Population.new(MAX_HOSTILES)
	_hostile_life = PackedFloat32Array(); _hostile_life.resize(MAX_HOSTILES)
	queue = HitQueue.new(EVENT_BUDGET, MAX_ENEMIES)
	director = SpawnDirector.new()
	# The WHOLE campaign, plotted before the first frame: three arenas and the
	# corridors between them on one grid. Generated from the player's start,
	# because the spawn-safe margin is measured from wherever they actually are.
	terrain = Terrain.new(ARENA_SIZE, SpawnDirector.CAMPAIGN_SUBNETS, _rng.seed)
	terrain.generate(_rng.seed, player_pos)

	_buf = PackedInt32Array(); _buf.resize(1024)
	_counts = PackedInt32Array(); _counts.resize(4)
	_pos_arrays = [null, null, null, null]
	_skips = [null, null, null, null]
	_fire_acc = PackedFloat32Array(); _fire_acc.resize(Loadout.MAX_EXPLOITS)
	_fire_cd = PackedFloat32Array(); _fire_cd.resize(Loadout.MAX_EXPLOITS)
	_ward_left = PackedFloat32Array(); _ward_left.resize(Loadout.MAX_EXPLOITS)
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
	_spawn_hp = PackedFloat32Array(); _spawn_hp.resize(MAX_ENEMIES)
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

	var table := ModuleTable.by_id()
	loadout = Loadout.new()
	loadout.start(table[&"packet"], table[&"interval"])
	loadout.mult = PlayerStats.mults(SaveGame.multipliers())
	_sheet = PlayerStats.sheet(SaveGame.player_sheet())
	player_health = _sheet[&"integrity"]
	pickup_radius = _sheet[&"pickup_radius"]
	_unlocked = SaveGame.unlocked_modules()
	_recompile()

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

	var ui := CanvasLayer.new()
	ui.set_script(load("res://scripts/run/ui.gd"))
	add_child(ui)
	ui.bind(self)

func _eff_integrity() -> float:
	return _sheet[&"integrity"]

## Max over live wards, never a sum. A module id occupies one slot now, but a
## single exploit can still carry ward_* on two modules at once — a TRIGGER and
## a PAYLOAD both may — so summing would buy double magnitude at zero uptime
## cost, which is the build the design explicitly rejects. Compiler.MAX_FOLD_KEYS
## folds the same way for the same reason.
func _ward_max(key: StringName) -> float:
	var best := 0.0
	for ei in mini(_ward_left.size(), resolved.size()):
		if _ward_left[ei] > 0.0:
			best = maxf(best, float(resolved[ei].get(key)))
	return best

func _eff_armor() -> float:
	return _sheet[&"armor"] + _ward_max(&"ward_armor")

func _eff_defense() -> float:
	return _sheet[&"defense"] + _ward_max(&"ward_defense")

func _eff_clock_speed() -> float:
	var v: float = _sheet[&"clock_speed"] + _ward_max(&"ward_clock_speed")
	# Applied last, so a slow zone cuts the total rather than the base and
	# cannot be out-scaled by buying clock_speed in the shop.
	if _zone_slow_player:
		v *= Terrain.SLOW_FACTOR
	return v

func _mitigated(amount: float) -> float:
	return PlayerStats.mitigate(amount, _eff_armor(), _eff_defense())

func _recompile() -> void:
	resolved = loadout.compile_all()
	_rebuild_execute_table()
	emit_signal("stats_changed")

## Rebuilt with `resolved`, so the drain always reads the current build.
func _rebuild_execute_table() -> void:
	_execute_by_exploit.resize(resolved.size())
	for i in resolved.size():
		_execute_by_exploit[i] = resolved[i].execute_below

# ---------------------------------------------------------------- the tick ---

func _physics_process(dt: float) -> void:
	# PRESENTATION, above the guard, every frame, unconditionally.
	#
	# Everything below the guard stops the moment the run ends or an overlay
	# opens. That is right for simulation and wrong for presentation: the death
	# shake would render zero frames, the effects would freeze mid-decay, and —
	# worst — the hitstop would never be released, because all three of its
	# triggers set one of these three flags on the frame they fire. Engine
	# .time_scale is process-global, so that leak survives back to the shell.
	_present(dt)

	if paused or user_paused or not alive or won:
		return

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
	if phase == Phase.FIGHTING:
		_step1_spawn(dt)
	_step2_integrate(dt)
	_step2c_gate()
	_step2d_collapse(dt)
	_step2e_blocks(dt)
	_step2b_zones(dt)
	_step3_rebuild()
	_step4_steer()
	_step5_fire(dt)
	_step6_detect(dt)
	_step6b_hostiles(dt)
	_steps78_drain()
	_step9_recycle()
	_step9b_splits()

	_update_renderers()

## The presentation half of the tick, run above the guard on a clock
## Engine.time_scale cannot shrink.
##
## Time.get_ticks_msec rather than the engine delta: at a hitstop's 0.05 the
## physics RATE is unchanged (measured, Godot 4.7) but each delta is 1/1200s, so
## a dt-fed 60ms deadline would take 1.2s of wall clock to expire.
func _present(dt: float) -> void:
	# Two different clocks, for two different jobs.
	#
	# AGING runs on unscaled FRAME time — the engine delta divided back out by
	# the scale that shrank it. Frame-coherent, so a headless suite stepping
	# _physics_process thousands of times a second ages effects at the same rate
	# a player would; a wall-clock delta there would be ~0 per tick and let
	# _fx_line grow without bound for the whole campaign.
	#
	# The HITSTOP DEADLINE runs on the wall clock, because a real-time pause is
	# the entire point of it and frame time is what the pause distorts.
	#
	# Both are immune to Engine.time_scale, which was the requirement.
	var udt := minf(dt / maxf(Engine.time_scale, 0.0001), MAX_PRESENT_DT)

	if feel.release_hitstop(Time.get_ticks_msec()):
		Engine.time_scale = 1.0

	feel.step(udt)
	_age_fx(udt)
	_vignette = maxf(0.0, _vignette - udt * 2.5)

	# The shake preference multiplies the composed offset, outside Feel and
	# after the square — folded into trauma it would scale quadratically and a
	# legal shake of 2.0 would give 4x.
	_camera.global_position = to_iso(player_pos) \
		+ feel.shake_offset() * _shake_pref
	queue_redraw()

## Belt and braces, and UNCONDITIONAL. The release above lives in a tick that
## goes away with the scene, so anything still live at teardown has nothing left
## to clear it — quitting during the 60ms hitstop a death just started would
## otherwise leave the whole process at 0.05.
func _exit_tree() -> void:
	Engine.time_scale = 1.0

## Set a hitstop and drop the engine scale to match. Rare events only: at the
## enemy cap a per-kill hitstop is a permanent stutter, not emphasis.
func _hitstop() -> void:
	feel.start_hitstop(Time.get_ticks_msec())
	Engine.time_scale = feel.time_scale()

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
	for s in director.step(dt, player_pos, SPAWN_RING):
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
			_spawn_at(player_pos + Vector2(cos(a), sin(a)) * 420.0),
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
			var at: Vector2 = entry[0] + Vector2(
				_card_rng.randf_range(-34.0, 34.0),
				_card_rng.randf_range(-34.0, 34.0))
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
	var a := _card_rng.randf() * TAU
	var at := _spawn_at(player_pos + Vector2(cos(a), sin(a)) * 620.0)
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
	# Polled through the InputMap: WASD, arrows, D-pad and left stick.
	#
	# input_override is a WORLD direction — it is a simulation hook for headless
	# drivers, which reason in world space. Keyboard input is SCREEN-relative and
	# is unprojected below, so W moves you up the screen rather than up the world
	# axis (which under the projection points diagonally).
	var input := Vector2.ZERO
	var world_dir := Vector2.ZERO
	if input_override != null:
		world_dir = (input_override as Vector2).normalized()
	else:
		# One call reads both axes, so an analog stick comes along for free —
		# the InputMap carries the keyboard and the gamepad bindings together
		# and neither can drift from the other.
		input = Input.get_vector("move_left", "move_right",
			"move_up", "move_down")
	if input.length_squared() > 0.0:
		# Uniform SCREEN speed, not uniform world speed.
		#
		# Normalising the WORLD direction keeps world speed constant, which makes
		# on-screen speed inherit the 2:1 squash — left/right moves twice as fast
		# as up/down, which is what makes the controls feel lopsided. Because
		# to_iso(from_iso(d)) == d exactly, feeding the unprojected direction
		# through WITHOUT renormalising makes the on-screen velocity exactly
		# clock_speed in every direction.
		#
		# The trade is that world speed now varies with heading (fastest along
		# the screen vertical, where the projection compresses most). That is the
		# right way round for a game where every dodge is judged on screen.
		world_dir = from_iso(input.normalized())
	var pos_before := player_pos
	if world_dir.length_squared() > 0.0:
		player_pos = terrain.slide(player_pos,
			world_dir * _eff_clock_speed() * dt)
	# Clamped to the GRID, not the arena: the corridor lies legitimately outside
	# the arena rect, and the margin's solid cells are what actually stop you.
	player_pos = player_pos.clamp(terrain.origin + Vector2(40, 40),
		terrain.origin + terrain.size - Vector2(40, 40))
	player_vel = (player_pos - pos_before) / maxf(dt, 0.0001)
	if player_iframe > 0.0:
		player_iframe -= dt
	for wi in _ward_left.size():
		if _ward_left[wi] > 0.0:
			_ward_left[wi] -= dt

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
				_fx_ring.append([enemies.pos[i], 40.0, FX_LIFE * 5.0,
					Color(2.4, 2.2, 2.0)])
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
			projectiles.pos[i] = player_pos + Vector2(cos(_orbit_phase[i]),
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
				var mo := _proj_owner[i]
				_detonate(i, resolved[mo].radius if mo >= 0 and mo < resolved.size() else 0.0)
			continue
		var pe := _proj_owner[i]
		if pe >= 0 and pe < resolved.size() and resolved[pe].homing > 0.0:
			var tj := _proj_target[i]
			_proj_reacquire[i] = maxf(0.0, _proj_reacquire[i] - dt)
			# Re-acquire when the bound target has died or its slot recycled.
			if _proj_reacquire[i] <= 0.0 and (tj < 0 or tj >= enemies.count \
					or enemies.generation[tj] != _proj_target_gen[i] \
					or enemies.state[tj] != Population.ALIVE):
				tj = _pick_target(HOMING_REACQUIRE, resolved[pe].targeting,
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
					-resolved[pe].homing * dt, resolved[pe].homing * dt)
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
	for i in shards.count:
		var d := player_pos - shards.pos[i]
		# Magnet reach. Was 6x the pickup radius (288 px), which meant shards
		# came to you from most of the screen and collection was never a
		# positioning decision.
		if d.length() < pickup_radius * 2.2:
			shards.pos[i] += d.normalized() * 300.0 * dt

func _age_fx(dt: float) -> void:
	for f in enemies.count:
		if _hit_flash[f] > 0.0:
			_hit_flash[f] = maxf(0.0, _hit_flash[f] - dt * HIT_FLASH_DECAY)
	var i := 0
	while i < _fx_line.size():
		_fx_line[i][2] -= dt
		if _fx_line[i][2] <= 0.0:
			_fx_line.remove_at(i)
		else:
			i += 1
	i = 0
	while i < _fx_ring.size():
		_fx_ring[i][2] -= dt
		if _fx_ring[i][2] <= 0.0:
			_fx_ring.remove_at(i)
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
	grid.set_centre(player_pos)
	grid.rebuild(_pos_arrays, _counts, _skips)

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
		if here.distance_squared_to(player_pos) > STEER_RANGE_SQ:
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
		enemies.force[i] = push * 2.2 + terrain.avoid(here, player_pos - here)
		i += STEER_SLICES

## Event triggers respond only when off cooldown. Returns false when the
## exploit is still recovering, so callers can skip the emit.
## Fire every exploit whose trigger matches. The event triggers all share this;
## each hook only has to name its kind.
func _fire_trigger(kind: int) -> void:
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == kind:
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
	for ei in _fire_cd.size():
		if _fire_cd[ei] > 0.0:
			_fire_cd[ei] -= dt
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if r.inert:
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

func _emit_vector(ei: int, r: ResolvedExploit) -> void:
	feel.emit(Synth.fire_id(r.vector_kind))
	_trigger_fires[ei] = _trigger_fires.get(ei, 0) + 1
	# Before the match, deliberately. BEAM and CHAIN return early when they have
	# no target, and a defensive build on those vectors must still ward — it has
	# already spent its cooldown by the time it reaches here, because
	# _try_event_fire sets _fire_cd before calling this.
	if r.ward_duration > 0.0:
		_ward_left[ei] = r.ward_duration
	# A shielding exploit grants its pool on fire, capped rather than stacked:
	# shield folds by MAX for the same reason.
	if r.shield > 0.0:
		player_shield = maxf(player_shield, r.shield)
	match r.vector_kind:
		Module.VectorKind.BROADCAST:
			_fx_ring.append([player_pos, r.radius, FX_LIFE, Color(0.5, 1.7, 1.1)])
			var n := grid.query_radius_into(player_pos, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(n, _buf.size()):
				_hit(ei, r, Grid.index_of(_buf[k]))
		Module.VectorKind.BEAM:
			var target := _pick_target(r.radius, r.targeting)
			if target < 0:
				return
			var dir := (enemies.pos[target] - player_pos).normalized()
			_fx_line.append([player_pos, player_pos + dir * r.radius, FX_LIFE,
				Color(2.2, 1.4, 2.6)])
			var n2 := grid.query_radius_into(player_pos + dir * r.radius * 0.5,
				r.radius * 0.5, _buf, Grid.M_ENEMY)
			var struck := 0
			for k in mini(n2, _buf.size()):
				if struck > r.pierce:
					break
				_hit(ei, r, Grid.index_of(_buf[k]))
				struck += 1
		Module.VectorKind.CONE:
			# A broadcast query filtered by ANGLE. Cheap, and it reads completely
			# differently because it demands facing.
			var ct := _pick_target(r.radius, r.targeting)
			if ct < 0:
				return
			var cdir := (enemies.pos[ct] - player_pos).normalized()
			_fx_line.append([player_pos, player_pos + cdir * r.radius, FX_LIFE,
				Color(2.0, 1.6, 0.8)])
			var cn := grid.query_radius_into(player_pos, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(cn, _buf.size()):
				var cj := Grid.index_of(_buf[k])
				var to_e := enemies.pos[cj] - player_pos
				if to_e.length_squared() < 0.01:
					_hit(ei, r, cj)
					continue
				if absf(to_e.normalized().angle_to(cdir)) <= CONE_HALF_ANGLE:
					_hit(ei, r, cj)
		Module.VectorKind.PULSE:
			_fx_ring.append([player_pos, r.radius, FX_LIFE * 1.6,
				Color(0.9, 1.4, 2.2)])
			var pn := grid.query_radius_into(player_pos, r.radius, _buf, Grid.M_ENEMY)
			for k in mini(pn, _buf.size()):
				var pj := Grid.index_of(_buf[k])
				_hit(ei, r, pj)
				if r.knockback > 0.0:
					var away := enemies.pos[pj] - player_pos
					if away.length_squared() > 0.01:
						apply_knockback(pj, away.normalized() * r.knockback)
		Module.VectorKind.MINE:
			# A projectile with no velocity and a proximity fuse, so mines cost
			# no new population and inherit terrain collision for free.
			var mines: int = maxi(int(r.split_count), 1)
			for sm in mines:
				var at := player_pos
				if mines > 1:
					# Through nearest_open: player_pos is always walkable, so a
					# single mine never needed this, but a ring of three can put
					# two of them inside a wall where nothing will ever trip them.
					at = terrain.nearest_open(at + Vector2(MINE_SPREAD, 0.0).rotated(
						TAU * float(sm) / float(mines)))
				var mi := projectiles.spawn(at, Vector2.ZERO, 1.0,
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
				var oi := projectiles.spawn(player_pos, Vector2.ZERO, 1.0,
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
			var t2 := _pick_target(r.radius, r.targeting)
			if t2 < 0:
				return
			_hit(ei, r, t2)
			_fx_line.append([player_pos, enemies.pos[t2], FX_LIFE, Color(1.0, 2.2, 1.6)])
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
				_fx_line.append([from, enemies.pos[picked], FX_LIFE, Color(1.0, 2.2, 1.6)])
				visited.append(picked)
				from = enemies.pos[picked]
				hops += 1
		_:
			# The viewport covers ~1113x626 world units at this zoom, so the
			# corner is ~640 away. Targeting at 1400 let packets fire at enemies
			# well off-screen — and made every shot walk the entire grid.
			var t3 := _pick_target(VIEW_RANGE, r.targeting)
			var dir2 := Vector2.RIGHT if t3 < 0 else (enemies.pos[t3] - player_pos).normalized()
			var shots: int = maxi(int(r.split_count), 1)
			for sp in shots:
				# Centred on the aim: 1 shot is dead on, 3 is -spread/0/+spread.
				var off := (float(sp) - float(shots - 1) * 0.5) * SPLIT_SPREAD
				var pi := projectiles.spawn(player_pos,
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

## `from` is where the shot came from. Defaults to the player, which is true for
## broadcast, chain and beam; packets pass their own position, because a packet
## that flew round behind something did not hit it from the front.
func _hit(ei: int, r: ResolvedExploit, target: int,
		from: Vector2 = Vector2.INF) -> void:
	if target < 0 or target >= enemies.count:
		return
	if from == Vector2.INF:
		from = player_pos
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
	if ei >= 0 and ei < resolved.size() and radius > 0.0:
		var r: ResolvedExploit = resolved[ei]
		feel.add_trauma(0.15)
		_fx_ring.append([projectiles.pos[i], radius, FX_LIFE * 1.5,
			Color(2.2, 1.2, 0.5)])
		var n := grid.query_radius_into(projectiles.pos[i], radius, _buf,
			Grid.M_ENEMY)
		for k in mini(n, _buf.size()):
			_hit(ei, r, Grid.index_of(_buf[k]), projectiles.pos[i])
	_mine_left[i] = 0.0
	projectiles.state[i] = Population.DEAD

## A projectile that STOPS — out of travel, into a wall, or out of pierce —
## detonates if it carries a blast, and simply dies otherwise.
func _expire_projectile(i: int) -> void:
	var ei := _proj_owner[i]
	if ei >= 0 and ei < resolved.size() and resolved[ei].blast_radius > 0.0:
		_detonate(i, resolved[ei].blast_radius)
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
## `from` is where the scan SCORES from. It defaults to the player, which is what
## the four fire-path sites want; a homing projectile already in flight passes
## its own position, or a shot behind the swarm would re-acquire across the arena.
func _pick_target(within: float, mode: int = Module.Targeting.NEAREST,
		from: Vector2 = Vector2.INF) -> int:
	if from == Vector2.INF:
		from = player_pos
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
			if ei < resolved.size():
				_hit(ei, resolved[ei], j, projectiles.pos[i])
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

	# Player contact. Enemies are not physics bodies, so this is a grid query —
	# an Area2D cannot overlap a packed array.
	if player_iframe <= 0.0:
		var n3 := grid.query_radius_into(player_pos, PLAYER_RADIUS + ENEMY_RADIUS,
			_buf, Grid.M_ENEMY)
		if n3 > 0:
			var t = enemy_types[enemies.type_index[Grid.index_of(_buf[0])]]
			_damage_player(t.contact_damage)

	# Pickups.
	var n4 := grid.query_radius_into(player_pos, pickup_radius, _buf, Grid.M_SHARD)
	for k in mini(n4, _buf.size()):
		shards.state[Grid.index_of(_buf[k])] = Population.DEAD
		_gain_xp(1)

func _damage_player(amount: float) -> void:
	# Triggers BEFORE the subtraction, so an on_damage_taken ward is up for the
	# hit that summoned it rather than the next one. ON_DAMAGE_TAKEN fires per
	# damage instance the player actually takes — not from a loop over
	# terminally-marked entities, which would fire it once per run, at game over.
	#
	# No recursion: the path is _try_event_fire -> _emit_vector -> _hit ->
	# queue.append, and nothing re-enters here.
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_DAMAGE_TAKEN:
			_try_event_fire(ei, r)
	# The shield is in the way, so it pays first and unmitigated: armour reducing
	# a hit the shield was going to eat entirely would make the two multiply.
	if player_shield > 0.0:
		var eaten := minf(player_shield, amount)
		player_shield -= eaten
		amount -= eaten
		if amount <= 0.0:
			player_iframe = IFRAMES
			emit_signal("stats_changed")
			return
	player_health -= _mitigated(amount)
	# Proportional, and the RATIO is clamped: a pulse or a hazard tick can
	# exceed full integrity, and an unclamped ratio would put trauma past 1.0
	# where MAX_OFFSET stops being a maximum.
	feel.add_trauma(0.25 + 0.5 * clampf(amount / maxf(_eff_integrity(), 1.0),
		0.0, 1.0))
	feel.emit("hurt")
	_vignette = 1.0
	player_iframe = IFRAMES
	if _low_armed and player_health < _eff_integrity() * LOW_INTEGRITY_FRACTION:
		_low_armed = false
		feel.emit("low_integrity")
		_fire_trigger(Module.TriggerKind.ON_LOW_INTEGRITY)
	elif player_health >= _eff_integrity() * LOW_INTEGRITY_FRACTION:
		_low_armed = true
	if player_health <= 0.0 and alive and not won:
		_die()
	emit_signal("stats_changed")

## Extracted so the zone pass can reach it: a hazard kills exactly the way a
## swarm does, and two copies of the banking rules would drift.
func _die() -> void:
	player_health = 0.0
	alive = false
	# Both of these only animate because _present() runs above the tick guard.
	feel.add_trauma(0.7)
	feel.emit("death")
	_hitstop()
	# Salvage is lost, but kills and flips still count toward unlocks —
	# otherwise a losing run gives nothing and the meta has no reason to exist
	# after a death, which is exactly what it is for.
	_bank_progress(false)
	emit_signal("run_ended", false, 0)

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

func _spawn_enemy_state(i: int, hp: float,
		behaviour: int = EnemyTable.Behaviour.CHASE) -> void:
	_worm_id[i] = 0
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
	var to_player := player_pos - enemies.pos[i]
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
			return to_player.normalized() * sp
	return to_player.normalized() * sp

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
			return to_player.normalized() * sp
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
	_fx_ring.append([enemies.pos[i], 700.0, FX_LIFE * 8.0, Color(2.2, 0.5, 0.4)])
	if terrain.has_line_of_sight(enemies.pos[i], player_pos):
		_damage_player(PULSE_DAMAGE)

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
		return toward * sp
	if d < RANGED_STANDOFF - 60.0:
		return -toward * sp
	return Vector2.ZERO

func _fire_hostile(from: Vector2) -> void:
	# Lead the player, so standing still is punished and moving is rewarded.
	var lead := player_pos + player_vel * 0.35
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
		if not gone and hostiles.pos[i].distance_to(player_pos) \
				< HOSTILE_RADIUS + PLAYER_RADIUS:
			_damage_player(HOSTILE_DAMAGE)
			gone = true
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
	var d := to_player.length()
	if d < 0.001:
		return Vector2.ZERO
	var toward := to_player / d
	if d > SUPPORT_STANDOFF + 40.0:
		return toward * sp
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
	var lead := to_player + player_vel * FLANK_LEAD
	if lead.length_squared() < 0.0001:
		return to_player.normalized() * sp
	var dir := lead.normalized()
	# Tangential component scaled by how fast the player is ACTUALLY moving:
	# circling a stationary target is just a worse chase.
	var speed_frac := clampf(player_vel.length() / 220.0, 0.0, 1.0)
	var tangent := Vector2(-dir.y, dir.x)
	# Arc the way the player is GOING. Either perpendicular is a valid tangent
	# and the wrong one swings out behind them — which is a chase with extra
	# steps, and at this magnitude it could even cancel the lead entirely.
	if tangent.dot(player_vel) < 0.0:
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
	_zone_slow_player = false
	terrain.step_temp_zones(dt)
	var pz := terrain.zone_at(player_pos)
	if pz < 0:
		pz = terrain.temp_zone_at(player_pos)
	if pz == Terrain.Kind.HAZARD:
		# Deliberately NOT through the contact-damage path: iframes exist to stop
		# a swarm chewing through you on touch, and a hazard you are standing in
		# is not a contact event. Armour and defence still apply.
		player_health -= _mitigated(Terrain.HAZARD_DPS * dt)
		if player_health <= 0.0 and alive and not won:
			_die()
	elif pz == Terrain.Kind.SLOW:
		_zone_slow_player = true
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
		match terrain.zone_at(enemies.pos[i]):
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
				if _numbers_pref:
					var ex := queue.hit_exploit[k]
					var dmg: float = resolved[ex].damage if ex >= 0 \
						and ex < resolved.size() else 0.0
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
			for ei in resolved.size():
				var r: ResolvedExploit = resolved[ei]
				if not r.inert and r.trigger_kind == Module.TriggerKind.ON_HIT:
					_try_event_fire(ei, r)

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
	kills += 1
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
		if not paused:
			_offer_cards()
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
			emit_signal("run_ended", true, salvage)
	_drop_shards(i)
	for ei in resolved.size():
		var r: ResolvedExploit = resolved[ei]
		if not r.inert and r.trigger_kind == Module.TriggerKind.ON_KILL:
			_try_event_fire(ei, r)
	var killer := queue.killer_exploit[i]
	if killer >= 0 and killer < resolved.size():
		var lifesteal: float = resolved[killer].lifesteal
		if lifesteal > 0.0:
			player_health = minf(_eff_integrity(), player_health + lifesteal)

## A flipped enemy drops the same shards a killed one does, so a corruption
## build does not starve its own level-ups in proportion to how well it works.
func _on_flip(i: int) -> void:
	flips += 1
	feel.emit("flip")
	_fire_trigger(Module.TriggerKind.ON_FLIP)
	_drop_shards(i)
	var cap := BOTNET_BASE_CAP
	for r in resolved:
		cap += r.botnet_cap
	if botnet.count >= mini(cap, MAX_BOTNET):
		return
	var src := queue.flipper_exploit[i]
	var corr := 6.0
	if src >= 0 and src < resolved.size():
		corr = maxf(resolved[src].corruption, 1.0)
	var bi := botnet.spawn(enemies.pos[i], Vector2.ZERO, 1.0, ENEMY_RADIUS, 0)
	if bi >= 0:
		_botnet_ratio[bi] = BOTNET_BASE_RATIO * corr
		_botnet_life[bi] = BOTNET_BASE_LIFETIME

func _drop_shards(i: int) -> void:
	var t = enemy_types[enemies.type_index[i]]
	for s in t.shard_value:
		shards.spawn(enemies.pos[i] + Vector2(_rng.randf_range(-8, 8),
			_rng.randf_range(-8, 8)), Vector2.ZERO, 1.0, 4.0, 0)

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

func _hp_mult() -> float:
	return SpawnDirector.hp_mult(subnet, director.elapsed)

func _refresh_thresholds() -> void:
	var f := SpawnDirector.threshold_mult(subnet)
	for i in enemy_types.size():
		thresholds[i] = enemy_types[i].corruption_threshold * f

func _bank_progress(with_salvage: bool) -> void:
	var s := (salvage - int(_banked[&"salvage"])) if with_salvage else 0
	SaveGame.bank(s, kills - int(_banked[&"kills"]), flips - int(_banked[&"flips"]))
	if with_salvage:
		_banked[&"salvage"] = salvage
	_banked[&"kills"] = kills
	_banked[&"flips"] = flips

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
	var frac := collapse_left / COLLAPSE_SECONDS
	terrain.collapse_to(int(float(terrain.max_dist) * frac))

	var pc := terrain.cell_index(player_pos)
	if pc != _route_cell:
		_route_cell = pc
		_route = terrain.route_from(player_pos)

	# Lethal means lethal: no iframes, no mitigation. Armour does not help when
	# the floor is gone.
	if terrain.is_void(player_pos) and alive and not won:
		_die()
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
	if blocks.tick(dt, player_pos, phase == Phase.FIGHTING,
			Callable(terrain, "nearest_open"), _block_rng):
		_block_payout()

## What a completed hold pays, in priority order.
func _block_payout() -> void:
	var matches := []
	for m in loadout.matched_recipes():
		if loadout.can_fuse(m[0], m[1].fused):
			matches.append(m)

	# A fusion offer PAUSES the run and waits for choose_fusion/decline_fusion.
	# With nobody connected there is nobody to unpause it, and _physics_process
	# returns early on `paused` forever: the run deadlocks. Every headless driver
	# connects level_up_offered and nothing else, so this guard is what keeps an
	# autopiloted run that happens to assemble a maxed triple from hanging the
	# perf gate. The drivers also get a handler; the design must not depend on it.
	if not matches.is_empty() and not fusion_offered.get_connections().is_empty():
		_pending_fusions = matches
		paused = true
		emit_signal("fusion_offered", matches)
		return

	var seed_m := _targeted_module()
	if seed_m != null and _card_rng.randf() < TARGETED_ODDS:
		pending_levels += 1
		_offer_cards(CardMode.SEEDED, seed_m)
		return

	var roll := _card_rng.randf()
	if roll < 0.40:
		salvage += 150 * subnet          # subnet starts at 1
		emit_signal("stats_changed")
	elif roll < 0.70:
		# player_health is the mutable pool; _eff_integrity() is the CAP it is
		# measured against. There is no `integrity` member.
		player_health = minf(_eff_integrity(),
			player_health + _eff_integrity() * 0.25)
		emit_signal("stats_changed")
	else:
		pending_levels += 1
		_offer_cards(CardMode.RANK_ONLY)

func choose_fusion(index: int) -> void:
	# Bounds-checked against the PENDING list, not against the loadout: a stale
	# index from a screen the player already declined must consume nothing, and
	# Loadout.fuse re-checks can_fuse for the same reason.
	if index >= 0 and index < _pending_fusions.size():
		var m = _pending_fusions[index]
		loadout.fuse(m[0], m[1].fused)
		_recompile()
	_pending_fusions = []
	paused = false
	emit_signal("stats_changed")

func decline_fusion() -> void:
	# Declining costs nothing and the recipe stays matched, so the next block
	# offers it again. A fusion is permanent; refusing one must not be.
	_pending_fusions = []
	salvage += 25
	paused = false
	emit_signal("stats_changed")

## The module that would do the most for the build right now: one that completes
## a recipe a row is a single module short of, or failing that one that fills a
## slot keeping a row inert. The near-miss search itself lives in RecipeTable —
## it is a question about recipes, and the arena has no business knowing a
## recipe's shape. This only filters by what is unlocked and placeable.
func _targeted_module() -> Module:
	var mods := ModuleTable.by_id()
	var unlocked := {}
	for m in _unlocked:
		unlocked[m.id] = true
	for ex in loadout.exploits:
		var want := RecipeTable.near_miss(ex)
		if want == &"" or not unlocked.has(want):
			continue
		var cand: Module = mods[want]
		if not loadout.legal_targets(cand).is_empty():
			return cand
	# Nothing is one short: fall back to anything that un-inerts a row.
	for ex in loadout.exploits:
		if not ex.is_inert():
			continue
		var need := Module.Slot.VECTOR if ex.vector == null else Module.Slot.TRIGGER
		for m in _unlocked:
			if m.slot == need and not loadout.legal_targets(m).is_empty():
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
	if (player_pos - g.end).dot(g.dir) <= 0.5:
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
	_route = PackedInt32Array()
	_route_cell = -1
	terrain.clear_temp_zones()
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
	player_health = minf(_eff_integrity(),
		player_health + _eff_integrity() * SUBNET_CLEAR_HEAL)
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
	if pending_levels > 0 and not paused:
		_offer_cards()
	emit_signal("stats_changed")

## The unlocked table, plus every fused module the loadout currently holds.
## Fused modules are never in ModuleTable — they enter the pool only by being
## owned, and legal_targets then offers the single slot holding one, as a
## rank-up. That is how a fused weapon climbs 1->5 like anything else.
func _card_pool() -> Array:
	var pool := []
	var seen := {}
	for m in _unlocked:
		var targets := loadout.legal_targets(m)
		if targets.is_empty():
			continue          # nothing legal: not worth a card slot
		seen[m.id] = true
		pool.append([m, targets])
	for ex in loadout.exploits:
		if not ex.head_is_fused() or seen.has(ex.vector.module.id):
			continue
		var ft := loadout.legal_targets(ex.vector.module)
		if ft.is_empty():
			continue          # already at max rank
		seen[ex.vector.module.id] = true
		pool.append([ex.vector.module, ft])
	return pool

## Multiple thresholds crossed in one tick queue; screens show in sequence.
func _offer_cards(mode: int = CardMode.NORMAL, seed_module: Module = null) -> void:
	paused = true
	var pool := _card_pool()
	if mode == CardMode.RANK_ONLY:
		# Filter the TARGETS, not just the entries. Keeping a whole entry because
		# it contains a rank-up leaves its EMPTY_SLOT and REPLACE buttons on the
		# card, so the screen would be a guaranteed-rank-AVAILABLE screen rather
		# than a guaranteed rank. An empty result falls through to the ordinary
		# pool on purpose: it means nothing in the loadout can rank at all, and
		# an ordinary draw beats an empty screen.
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
	# Seeded so a run reproduces exactly from a bug report.
	for i in range(pool.size() - 1, 0, -1):
		var j := _card_rng.randi_range(0, i)
		var tmp = pool[i]; pool[i] = pool[j]; pool[j] = tmp
	if mode == CardMode.SEEDED and seed_module != null:
		# Front of the deck, not an extra card: the screen still shows three.
		for i in pool.size():
			if pool[i][0] != null and pool[i][0].id == seed_module.id:
				var tmp2 = pool[0]; pool[0] = pool[i]; pool[i] = tmp2
				break
	var cards := []
	for entry in pool:
		if cards.size() >= 3:
			break
		cards.append(entry)
	while cards.size() < 3:
		cards.append([null, []])        # salvage card fallback
	emit_signal("level_up_offered", cards)

func choose_card(m, target) -> void:
	if m == null:
		salvage += 50
	else:
		loadout.place_at(m, target.exploit, target.slot)
		_recompile()
	pending_levels = maxi(0, pending_levels - 1)
	paused = false
	if pending_levels > 0:
		_offer_cards()
	emit_signal("stats_changed")

func decline_card() -> void:
	salvage += 25
	pending_levels = maxi(0, pending_levels - 1)
	paused = false
	if pending_levels > 0:
		_offer_cards()
	emit_signal("stats_changed")

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

## Only enemies need per-frame colour (the corruption lerp) and per-frame glyph
## (type varies by slot). Projectiles, shards and botnet nodes are one colour and
## one glyph for the life of the pool, and MultiMesh instance buffers persist —
## so those are written once here instead of ~4000 setter calls every frame.
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

	_prime_constant_instances(_mm_proj, 4.0, Color(1.1, 1.7, 1.4))
	_prime_constant_instances(_mm_shard, 5.0, Color(0.5, 1.3, 1.7))
	_prime_constant_instances(_mm_botnet, 3.0, Color(1.6, 0.5, 1.6))

func _update_renderers() -> void:
	var mm := _mm_enemy.multimesh
	mm.visible_instance_count = enemies.count
	# Depth order: farther up the screen draws first. Buckets rather than a
	# comparison sort — 600 entities every frame, and the band resolution is far
	# finer than the overlap it resolves.
	_depth_sort()
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
		mm.set_instance_transform_2d(n, Transform2D(0.0, Vector2(s, s), 0.0, to_iso(enemies.pos[i])))
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
	for i in projectiles.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, to_iso(projectiles.pos[i])))
	mm = _mm_shard.multimesh
	mm.visible_instance_count = shards.count
	for i in shards.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, to_iso(shards.pos[i])))
	mm = _mm_botnet.multimesh
	mm.visible_instance_count = botnet.count
	for i in botnet.count:
		mm.set_instance_transform_2d(i, Transform2D(0.0, Vector2.ONE, 0.0, to_iso(botnet.pos[i])))

## Counting sort into screen-depth bands. O(n) with no comparisons, which is
## what makes per-entity depth ordering affordable at the enemy cap.
func _depth_sort() -> void:
	var n := enemies.count
	if n == 0:
		return
	for b in DEPTH_BANDS + 1:
		_band_count[b] = 0
	var lo := player_pos.x + player_pos.y - 1800.0
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
	return Rect2(player_pos - half, half * 2.0)

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

	# Orbiters and mines share the projectile pool, so they need to look like
	# what they are rather than like a shot that stopped.
	for i in projectiles.count:
		if _orbit_left[i] > 0.0:
			var op := to_iso(projectiles.pos[i])
			draw_circle(op, 6.0, Color(0.5, 1.6, 1.2, 0.30))
			draw_circle(op, 3.0, Color(0.7, 2.0, 1.5))
		elif _mine_left[i] > 0.0:
			# Pulsing, because a mine you forgot you placed is a mine that kills
			# you when the collapse pushes you back over it.
			var mp := to_iso(projectiles.pos[i])
			var beat := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.006)
			draw_circle(mp, 5.0 + 3.0 * beat, Color(2.0, 1.1, 0.4, 0.25 + 0.3 * beat))
			draw_circle(mp, 2.5, Color(2.2, 1.3, 0.5))

	# Enemy fire. Distinct from the player's: red, and with a soft halo so a
	# shot crossing a busy field is still findable.
	for i in hostiles.count:
		var hpos := to_iso(hostiles.pos[i])
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
			ring.append(to_iso(enemies.pos[i]
				+ Vector2(cos(ta), sin(ta)) * (14.0 + 26.0 * tell)))
		draw_polyline(ring, Color(1.9, 0.9, 0.4, 0.85 * (1.0 - tell)), 2.0)

	# Shot visuals, oldest fading out. Drawn under the ship.
	for fx in _fx_line:
		var f: float = fx[2] / FX_LIFE
		var c: Color = fx[3]
		draw_line(to_iso(fx[0]), to_iso(fx[1]), Color(c.r, c.g, c.b, f), 1.0 + 2.5 * f)
	for fx in _fx_ring:
		var f2: float = fx[2] / FX_LIFE
		var c2: Color = fx[3]
		var pts := PackedVector2Array()
		for k in 33:
			var a2 := TAU * k / 32.0
			pts.append(to_iso(fx[0] + Vector2(cos(a2), sin(a2)) * fx[1] * (1.0 - f2 * 0.25)))
		draw_polyline(pts, Color(c2.r, c2.g, c2.b, f2 * 0.85), 1.0 + 2.0 * f2)

	# Arrivals. Two phases: rings converging on the destination while glyph
	# columns rain down the isometric vertical, then a shockwave expanding out
	# of it as the body lands. Orange for a mini-boss, violet for ICE.
	for i in enemies.count:
		if _arriving[i] <= 0.0:
			continue
		var ai := to_iso(enemies.pos[i])
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

	# The player, drawn screen-aligned at the projected position: a glyph that
	# tilts with the ground plane reads as debris, not as the thing you steer.
	#
	# A disc at PLAYER_RADIUS, so what you see is exactly what collides. The
	# arrow this replaced pointed somewhere — and the movement has no facing, so
	# the direction it pointed was never the direction anything happened in.
	var o := to_iso(player_pos)
	var c := Color(0.9, 1.8, 1.3) if player_iframe <= 0.0 else Color(1.9, 0.8, 0.8)
	draw_circle(o, PLAYER_RADIUS, Color(c.r * 0.22, c.g * 0.22, c.b * 0.22))
	draw_arc(o, PLAYER_RADIUS, 0.0, TAU, 28, c, 2.0)
