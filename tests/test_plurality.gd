extends SceneTree

## The plurality census: every rule that used to say "the player" now says WHICH
## players, and this suite pins each one against a real two-slot run — the grid
## window and its snapping, the leash, nearest-LIVE targeting, inert DEAD and
## ABSENT slots, per-owner wards and attribution, the shared botnet pool, first
## shard pickup, void death per slot, the gate waiting on every LIVE slot, the
## block holder's payout, and roster scaling.

var failures := 0
var finished := {}

const CELL := 32.0
const MAX := 7200.0
const DT := 1.0 / 60.0

const CASES := ["window_at_the_minimum", "window_at_the_maximum",
	"edges_snap_to_cells", "two_slots_move_independently",
	"party_window_follows_the_party", "the_leash_holds_the_party",
	"dead_slot_is_skipped_by_targeting", "absent_slot_is_inert",
	"wards_and_kills_belong_to_their_owner", "flips_belong_to_their_owner",
	"the_botnet_cap_is_shared", "first_shard_pickup_wins",
	"the_void_kills_each_slot_alone", "the_gate_waits_for_every_live_slot",
	"block_payout_heals_holder_or_pays_the_pool", "scaling_follows_the_roster",
	"the_spawn_ring_cycles_live_slots"]

func _initialize() -> void:
	print("ROOTKIT — plurality census\n")
	SaveGame.use_fresh_state()
	window_at_the_minimum()
	window_at_the_maximum()
	edges_snap_to_cells()
	await two_slots_move_independently()
	await party_window_follows_the_party()
	await the_leash_holds_the_party()
	await dead_slot_is_skipped_by_targeting()
	await absent_slot_is_inert()
	await wards_and_kills_belong_to_their_owner()
	await flips_belong_to_their_owner()
	await the_botnet_cap_is_shared()
	await first_shard_pickup_wins()
	await the_void_kills_each_slot_alone()
	await the_gate_waits_for_every_live_slot()
	await block_payout_heals_holder_or_pays_the_pool()
	await scaling_follows_the_roster()
	await the_spawn_ring_cycles_live_slots()
	print("")
	for c in CASES:
		if not finished.has(c):
			print("  FAIL  case '%s' never finished — it aborted part way" % c)
			failures += 1
	if failures == 0: print("  PASS — all cases")
	else: print("  FAIL — %d assertion(s)" % failures)
	quit(1 if failures > 0 else 0)

func _check(label: String, got, want) -> void:
	if got == want or (got is float and want is float and abs(got - want) < 1e-4):
		print("  ok    %s" % label)
	else:
		print("  FAIL  %s — got %s, want %s" % [label, got, want])
		failures += 1

func _check_true(label: String, got: bool) -> void:
	_check(label, got, true)

func _grid() -> Grid:
	return Grid.new(Vector2.ZERO, Vector2(MAX, MAX), CELL, 4096)

func _profile(slot: int, name: String) -> Dictionary:
	return {"slot": slot, "name": name, "counters": SaveGame.session_counters()}

## A run whose session names `players` slots, all LIVE, this process at slot 0.
## Slot 0 is driven by input_override; the others by writing `inputs[s]`.
func _party_run(players: int) -> Node2D:
	var rows := []
	for s in players:
		rows.append(_profile(s, "p%d" % s))
	var raw := {"protocol": SessionRules.PROTOCOL, "session_id": 1,
		"seed": 20260830, "delay": 0, "choice_timeout": 0, "roster": rows}
	var desc := NetworkSession.validate_descriptor(raw)
	var r: Node2D = load("res://scenes/run.tscn").instantiate()
	r.configure_session(NetworkSession.create(desc, 0, NetworkSession.Role.HOST))
	root.add_child(r)
	await process_frame
	r.input_override = Vector2.ZERO
	return r

func _done(r: Node2D, name: String) -> void:
	r.free()
	await process_frame
	finished[name] = true

## Kill ICE straight through the drain so the subnet is CLEARED, the gate is
## open and the collapse field is built. The boss-kill hitstop is dropped: these
## cases step the tick directly.
func _clear_subnet(r: Node2D) -> void:
	var b = r.enemy_types[EnemyTable.ICE]
	var i: int = r.enemies.spawn(Vector2(200, 0), Vector2.ZERO, b.integrity,
		48.0, EnemyTable.ICE)
	r._on_death(i)
	r.hitstop_ticks = 0

# ------------------------------------------------------------ grid window ---

## The 3200-square floor is exactly 100 x 100 = 10,000 cells — the solo window,
## the common case the whole grid is sized around.
func window_at_the_minimum() -> void:
	var g := _grid()
	g.set_window(Rect2(Vector2.ZERO, Vector2(3200.0, 3200.0)))
	_check("the 3200 square is 10,000 live cells", g.live_cell_count(), 10000)
	finished["window_at_the_minimum"] = true

## The 7200-square cap is 225 x 225 = 50,625 cells — the fully-spread party
## window, the ceiling the backing arrays are preallocated for.
func window_at_the_maximum() -> void:
	var g := _grid()
	g.set_window(Rect2(Vector2.ZERO, Vector2(MAX, MAX)))
	_check("the 7200 square is 50,625 live cells", g.live_cell_count(), 50625)
	finished["window_at_the_maximum"] = true

## An unaligned rect snaps OUTWARD — origin floored, far edge ceiled — so a cell
## boundary never slides under an entity.
func edges_snap_to_cells() -> void:
	var g := _grid()
	g.set_window(Rect2(Vector2(10.0, 10.0), Vector2(3200.0, 3200.0)))
	_check("the origin floors to a cell boundary", g._origin, Vector2.ZERO)
	_check("the far edge ceils, adding a column", g._cols, 101)
	_check("so the unaligned window is 101 x 101", g.live_cell_count(), 101 * 101)
	g.set_window(Rect2(Vector2(64.0, -32.0), Vector2(3200.0, 3200.0)))
	_check("an aligned window keeps its origin", g._origin, Vector2(64.0, -32.0))
	_check("and is exactly 10,000 cells", g.live_cell_count(), 10000)
	finished["edges_snap_to_cells"] = true

# --------------------------------------------------------------- the party ---

## A two-slot roster starts both LIVE and moves each on its own input.
func two_slots_move_independently() -> void:
	var r: Node2D = await _party_run(2)
	_check("slot zero is live", r.slot_state[0], r.SlotState.LIVE)
	_check("slot one is live", r.slot_state[1], r.SlotState.LIVE)
	_check("slot two is absent", r.slot_state[2], r.SlotState.ABSENT)
	_check("both slots have a build", r._slot_exploits(1).size() > 0, true)
	var p0: Vector2 = r.player_pos[0]
	# A remote slot's input is a RECORD in the ring for the tick to consume.
	r.lockstep.submit(1, r.lockstep.executed, Vector2.RIGHT, -1, -1, -1)
	r._physics_process(DT)
	_check_true("slot one moved right", r.player_pos[1].x > 0.0)
	_check("slot zero stayed put on neutral input", r.player_pos[0], p0)
	await _done(r, "two_slots_move_independently")

## The grid window is the LIVE bounding box grown by 1600 a side, floored at a
## 3200 square, held inside the terrain, and snapped to cells.
func party_window_follows_the_party() -> void:
	var r: Node2D = await _party_run(2)
	r.player_pos[0] = Vector2.ZERO
	r.player_pos[1] = Vector2(1000.0, 0.0)
	r._step3_rebuild()
	_check("a 1000-wide party grows the window by 1000 on x",
		r.grid._cols, int(ceil(4200.0 / CELL)))
	_check("and not on y", r.grid._rows, 100)
	_check("the window origin is the box grown by 1600, cell-floored",
		r.grid._origin, Vector2(-1600.0, -1600.0))
	r.player_pos[1] = Vector2(100.0, 0.0)
	r._step3_rebuild()
	_check_true("a tight party never drops below the 3200 floor",
		r.grid._cols >= 100 and r.grid._rows >= 100)
	# Hard against the terrain corner: the window is held inside the grid.
	var corner: Vector2 = r.terrain.origin + Vector2(50.0, 50.0)
	r.player_pos[0] = corner
	r.player_pos[1] = corner
	r._step3_rebuild()
	_check("the window is clamped to the terrain origin",
		r.grid._origin, r.terrain.origin)
	await _done(r, "party_window_follows_the_party")

## No LIVE slot may end up more than LEASH from another on either axis. The
## overshooting axis alone is clamped, toward the rest of the party.
func the_leash_holds_the_party() -> void:
	var r: Node2D = await _party_run(2)
	r.player_pos[0] = Vector2.ZERO
	r.player_pos[1] = Vector2(3990.0, 200.0)
	var leash := float(SessionRules.LEASH)
	var held: Vector2 = r._leash(1, Vector2(4500.0, 200.0))
	_check("x is held at the leash", held.x, leash)
	_check("y is untouched", held.y, 200.0)
	var held2: Vector2 = r._leash(1, Vector2(3990.0, 4500.0))
	_check("y is held at the leash", held2.y, leash)
	_check("x is untouched", held2.x, 3990.0)
	_check("inside the leash nothing changes",
		r._leash(1, Vector2(3000.0, 100.0)), Vector2(3000.0, 100.0))
	r._die(1)
	_check("solo is unaffected", r._leash(0, Vector2(9000.0, 0.0)),
		Vector2(9000.0, 0.0))
	await _done(r, "the_leash_holds_the_party")

## An enemy targets its nearest LIVE slot for the whole decision; a DEAD slot is
## invisible to it.
func dead_slot_is_skipped_by_targeting() -> void:
	var r: Node2D = await _party_run(2)
	while r.enemies.count > 0:
		r.enemies.despawn(r.enemies.count - 1)
	r.player_pos[0] = Vector2.ZERO
	r.player_pos[1] = Vector2(300.0, 0.0)
	_check("the nearest live slot to (400,0) is slot one",
		r._nearest_live(Vector2(400.0, 0.0)), 1)
	var i: int = r.enemies.spawn(Vector2(400.0, 0.0), Vector2.ZERO, 50.0, 12.0, 0)
	r._spawn_enemy_state(i, 50.0)
	var t = r.enemy_types[0]
	# _behave scans the per-tick LIVE cache the integrate step packs; driving it
	# directly means packing that cache by hand.
	r._refresh_live_cache()
	var v: Vector2 = r._behave(i, t, DT)
	_check_true("a chaser heads for slot one", v.x < 0.0 and r._target_slot == 1)
	_check("and remembers its target for the steer pass", r._enemy_target[i], 1)
	r._die(1)
	_check("the run is still alive on slot zero", r.alive, true)
	_check("once slot one is dead, slot zero is nearest",
		r._nearest_live(Vector2(400.0, 0.0)), 0)
	r._refresh_live_cache()
	v = r._behave(i, t, DT)
	_check("and the chaser retargets slot zero", r._target_slot, 0)
	await _done(r, "dead_slot_is_skipped_by_targeting")

## An ABSENT slot is inert: its cooldowns freeze, it picks nothing up, and it
## takes no contact.
func absent_slot_is_inert() -> void:
	var r: Node2D = await _party_run(2)
	while r.enemies.count > 0:
		r.enemies.despawn(r.enemies.count - 1)
	r.player_pos[0] = Vector2.ZERO
	r.player_pos[1] = Vector2(600.0, 0.0)
	r.slot_state[1] = r.SlotState.ABSENT
	var gid: int = r._gid(1, 0)
	r._fire_cd[gid] = 1.0
	var hp_before: float = r.player_health[1]
	r.shards.spawn(r.player_pos[1], Vector2.ZERO, 1.0, 4.0, 0)
	var e: int = r.enemies.spawn(r.player_pos[1], Vector2.ZERO, 50.0, 12.0, 0)
	r._spawn_enemy_state(e, 50.0)
	var xp_before: int = r.xp
	r._physics_process(DT)
	_check("an absent slot's cooldown is frozen", r._fire_cd[gid], 1.0)
	_check("it picked nothing up", r.xp, xp_before)
	_check("and took no contact", r.player_health[1], hp_before)
	await _done(r, "absent_slot_is_inert")

## A ward armours only the slot whose exploit fired it, a kill credits only the
## owner of the killing exploit, and an unowned kill credits nobody.
func wards_and_kills_belong_to_their_owner() -> void:
	var r: Node2D = await _party_run(2)
	while r.enemies.count > 0:
		r.enemies.despawn(r.enemies.count - 1)
	var t := ModuleTable.by_id()
	var ex := Exploit.new()
	ex.place(t[&"broadcast"]); ex.place(t[&"interval"]); ex.place(t[&"sandbox"])
	r.loadouts[0].exploits.append(ex)
	r._recompile()
	var gid: int = r._gid(0, r.loadouts[0].exploits.size() - 1)
	var base0: float = r._eff_defense(0)
	var base1: float = r._eff_defense(1)
	r._emit_vector(gid, r.resolved[gid])
	_check_true("firing wards the owner", r._eff_defense(0) > base0)
	_check("and not the teammate", r._eff_defense(1), base1)

	var i: int = r.enemies.spawn(Vector2(100.0, 0.0), Vector2.ZERO, 5.0, 12.0, 0)
	r._spawn_enemy_state(i, 5.0)
	r._step3_rebuild()
	r.queue.begin_tick()
	r.queue.append(HitQueue.Kind.DAMAGE, r._gid(1, 0), i, r.enemies.generation[i],
		999.0)
	r._steps78_drain()
	_check("the killing exploit's owner is credited", r.kills[1], 1)
	_check("the other slot is not", r.kills[0], 0)

	var j: int = r.enemies.spawn(Vector2(120.0, 0.0), Vector2.ZERO, 5.0, 12.0, 0)
	r._spawn_enemy_state(j, 5.0)
	r._step3_rebuild()
	r.queue.begin_tick()
	r.queue.append(HitQueue.Kind.DAMAGE, -1, j, r.enemies.generation[j], 999.0)
	r._steps78_drain()
	_check("an unowned kill credits nobody: slot zero", r.kills[0], 0)
	_check("an unowned kill credits nobody: slot one", r.kills[1], 1)
	await _done(r, "wards_and_kills_belong_to_their_owner")

## A flip credits the flipping exploit's owner, and only that owner.
func flips_belong_to_their_owner() -> void:
	var r: Node2D = await _party_run(2)
	while r.enemies.count > 0:
		r.enemies.despawn(r.enemies.count - 1)
	var i: int = r.enemies.spawn(Vector2(100.0, 0.0), Vector2.ZERO, 50.0, 12.0, 0)
	r._spawn_enemy_state(i, 50.0)
	r._step3_rebuild()
	r.queue.begin_tick()
	r.queue.append(HitQueue.Kind.CORRUPTION, r._gid(0, 0), i,
		r.enemies.generation[i], 9999.0)
	r._steps78_drain()
	_check("the flipping exploit's owner is credited", r.flips[0], 1)
	_check("the other slot is not", r.flips[1], 0)
	await _done(r, "flips_belong_to_their_owner")

## The botnet is one shared pool, so its cap sums over every slot's build.
func the_botnet_cap_is_shared() -> void:
	var r: Node2D = await _party_run(2)
	var base: int = r._botnet_cap()
	r.resolved[r._gid(0, 0)].botnet_cap = 2
	r.resolved[r._gid(1, 0)].botnet_cap = 3
	_check("both slots' botnet_cap add to the shared cap", r._botnet_cap(), base + 5)
	await _done(r, "the_botnet_cap_is_shared")

## A shard within reach of two slots is collected exactly once, by the lower
## slot in walk order.
func first_shard_pickup_wins() -> void:
	var r: Node2D = await _party_run(2)
	while r.shards.count > 0:
		r.shards.despawn(r.shards.count - 1)
	while r.enemies.count > 0:
		r.enemies.despawn(r.enemies.count - 1)
	r.player_pos[0] = Vector2.ZERO
	r.player_pos[1] = Vector2(20.0, 0.0)
	r.shards.spawn(Vector2(10.0, 0.0), Vector2.ZERO, 1.0, 4.0, 0)
	r._step3_rebuild()
	var xp_before: int = r.xp
	r._step6_detect(DT)
	_check("one shard grants exactly one xp", r.xp - xp_before, 1)
	_check("and it is consumed", r.shards.state[0], Population.DEAD)
	await _done(r, "first_shard_pickup_wins")

## Voided ground kills the slot standing on it and no other.
func the_void_kills_each_slot_alone() -> void:
	var r: Node2D = await _party_run(2)
	_clear_subnet(r)
	r.player_pos[0] = Vector2.ZERO
	r.player_pos[1] = Vector2(200.0, 0.0)
	r.terrain.voided[r.terrain.cell_index(r.player_pos[1])] = 1
	r._step2d_collapse(DT)
	_check("the slot on void ground dies", r.slot_state[1], r.SlotState.DEAD)
	_check("the slot on solid ground lives", r.slot_state[0], r.SlotState.LIVE)
	_check("and the run goes on", r.alive, true)
	await _done(r, "the_void_kills_each_slot_alone")

## The subnet advances only when EVERY LIVE slot is past the gate line.
func the_gate_waits_for_every_live_slot() -> void:
	var r: Node2D = await _party_run(2)
	_clear_subnet(r)
	var g = r.terrain.gate()
	r.player_pos[0] = g.end + g.dir * 8.0
	r.player_pos[1] = g.pos - g.dir * 200.0
	r._step2c_gate()
	_check("one slot through is not enough", r.subnet, 1)
	r.player_pos[1] = g.end + g.dir * 8.0
	r._step2c_gate()
	_check("both through advances", r.subnet, 2)
	await _done(r, "the_gate_waits_for_every_live_slot")

## A completed block heals the holder when they can use it; otherwise the value
## goes to the shared salvage pool.
func block_payout_heals_holder_or_pays_the_pool() -> void:
	var r: Node2D = await _party_run(2)
	r.player_health[1] = 10.0
	var salvage_before: int = r.salvage
	_check_true("a hurt holder is healed", r._block_heal(1))
	_check_true("their integrity rose", r.player_health[1] > 10.0)
	_check("and salvage was untouched", r.salvage, salvage_before)
	_check("a full-health holder is not healed", r._block_heal(0), false)
	_check("the value went to the shared pool instead",
		r.salvage, salvage_before + 150 * r.subnet)
	await _done(r, "block_payout_heals_holder_or_pays_the_pool")

## Spawn rate multiplies by the roster size and enemy integrity by
## 1 + 0.5 per extra player — and neither drops when a slot dies.
func scaling_follows_the_roster() -> void:
	var r: Node2D = await _party_run(2)
	_check("the roster size is two", r._players, 2)
	_check("spawn rate doubles", r.director.rate_mult, 2.0)
	_check("integrity is 1.5x", r._hp_mult(),
		SpawnDirector.hp_mult(1, r.director.elapsed) * 1.5)
	r._die(1)
	_check("a death does not soften the enemies", r._hp_mult(),
		SpawnDirector.hp_mult(1, r.director.elapsed) * 1.5)
	await _done(r, "scaling_follows_the_roster")

## The spawn ring walks the LIVE slots in order and skips the dead.
func the_spawn_ring_cycles_live_slots() -> void:
	var r: Node2D = await _party_run(2)
	r._cycle_cursor = 0
	_check("first pick is slot zero", r._next_live_cycle(), 0)
	_check("then slot one", r._next_live_cycle(), 1)
	_check("then back to zero", r._next_live_cycle(), 0)
	r._die(1)
	_check("a dead slot is skipped", r._next_live_cycle(), 0)
	_check("every time", r._next_live_cycle(), 0)
	await _done(r, "the_spawn_ring_cycles_live_slots")
