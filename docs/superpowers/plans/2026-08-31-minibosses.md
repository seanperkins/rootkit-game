# Mini-bosses Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans.

**Goal:** Four set-piece enemies, one a minute, each with a signature mechanic no ordinary enemy has.

**Architecture:** A schedule beside the wave table fires each once. Each mini-boss is an `EnemyType` with a pool behaviour plus one bespoke mechanic hooked where that mechanic actually belongs — splitting after the tick, directional armour in `_hit`, afterimages in a bounded dynamic zone overlay, and a line-of-sight pulse walked over the occupancy grid.

**Spec:** `docs/superpowers/specs/2026-08-31-minibosses-design.md`

## Global Constraints

- Run tests with `tools/run_tests.sh`. A bare `PASS` is not evidence — the runner fails on any `SCRIPT ERROR`.
- Every test case marks itself finished on its last line.
- `EnemyTable.ICE` must stay the LAST index; new types are inserted before it. `run.WORM_TYPE` must stay pointing at the worm. Both are pinned by `test_behaviour.gd`.
- Nothing spawns or frees entities inside the drain. Splits are flagged and acted on after step 9, the way the subnet advance already is.
- The terrain zone grid is baked once and never mutated. Afterimages use a separate bounded overlay.
- Mini-bosses take `SpawnDirector.hp_mult` like everything else.
- Perf gate stood at p95 3.932 ms against a 10.4 ms budget.
- No AI attribution in commit messages.

---

### Task 1: The schedule

**Files:** `scripts/run/spawn_director.gd`, `scripts/run/run.gd`, `tests/test_minibosses.gd` (create)

**Interfaces:** `SpawnDirector.MINIBOSS_TIMES`, `SpawnDirector.due_minibosses(dt) -> Array` returning type indices crossed this step; `SpawnDirector.miniboss_fired: PackedByteArray`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_minibosses.gd` (standard harness) with:

```gdscript
func the_schedule_fires_each_once() -> void:
	var d := SpawnDirector.new()
	var seen := []
	var t := 0.0
	while t < SpawnDirector.SUBNET_SECONDS:
		for idx in d.due_minibosses(1.0 / 60.0):
			seen.append([snappedf(d.elapsed, 1.0), idx])
		d.elapsed += 1.0 / 60.0
		t += 1.0 / 60.0
	_check("four mini-bosses arrive", seen.size(), SpawnDirector.MINIBOSS_TIMES.size())
	# None in the last minute: ICE owns the subnet's ending and does not share
	# the stage.
	var late := 0
	for row in seen:
		if float(row[0]) > SpawnDirector.SUBNET_SECONDS - 60.0:
			late += 1
	_check("none in the last minute", late, 0)

	# A single tick that crosses a boundary must not double-fire.
	var d2 := SpawnDirector.new()
	d2.elapsed = SpawnDirector.MINIBOSS_TIMES[0] - 0.001
	var first: Array = d2.due_minibosses(0.5)
	d2.elapsed += 0.5
	var again: Array = d2.due_minibosses(0.5)
	_check("the crossing fires once", first.size(), 1)
	_check("and not again on the next step", again.size(), 0)

	# reset() clears the record, or subnet 02 would get no mini-bosses at all.
	d2.reset()
	_check("reset rearms them", d2.miniboss_fired[0], 0)
	finished["the_schedule_fires_each_once"] = true
```

- [ ] **Step 2: Run to verify it fails** — `MINIBOSS_TIMES` is not defined.

- [ ] **Step 3: Implement**

In `spawn_director.gd`:

```gdscript
## One a minute, and never in the last: ICE arrives at SUBNET_SECONDS and the
## subnet's ending is not a stage to share.
const MINIBOSS_TIMES := [60.0, 120.0, 180.0, 240.0]
const MINIBOSS_IDS := [&"fork_bomb", &"packet_filter", &"null_ptr", &"kernel_panic"]

var miniboss_fired: PackedByteArray

## Which mini-bosses this step crosses. Records each as fired, because a step is
## a range and a boundary inside it must produce exactly one arrival — testing
## `elapsed > time` alone fires every tick after it.
func due_minibosses(dt: float) -> Array:
	var out := []
	for k in MINIBOSS_TIMES.size():
		if miniboss_fired[k] != 0:
			continue
		if elapsed + dt >= MINIBOSS_TIMES[k]:
			miniboss_fired[k] = 1
			out.append(_idx(MINIBOSS_IDS[k]))
	return out
```

Size it in `_init` (`miniboss_fired.resize(MINIBOSS_TIMES.size())`) and clear it in `reset()`.

In `run.gd`'s `_step1_spawn`, before the boss check:

```gdscript
	for mb in director.due_minibosses(dt):
		_spawn_miniboss(mb)
```

```gdscript
## Mini-bosses arrive on the spawn ring like anything else, but announced: an
## arrival the player does not notice is not a set-piece.
func _spawn_miniboss(type_index: int) -> void:
	var t = enemy_types[type_index]
	var a := _card_rng.randf() * TAU
	var at := terrain.nearest_open(player_pos + Vector2(cos(a), sin(a)) * 620.0)
	var hp: float = t.integrity * _hp_mult()
	var idx := enemies.spawn(at, Vector2.ZERO, hp, 26.0, type_index)
	if idx < 0:
		return
	_spawn_enemy_state(idx, hp, t.behaviour)
	director.spawned += 1
	_fx_ring.append([at, 150.0, FX_LIFE * 6.0, Color(2.0, 0.7, 0.3)])
	emit_signal("stats_changed")
```

- [ ] **Step 4: Verify** — `tools/run_tests.sh --fast`. **Step 5: Commit** — `feat: a mini-boss schedule, one a minute`

---

### Task 2: The four types

**Files:** `data/enemy_table.gd`, `shaders/glyph.gdshader`, `tests/test_minibosses.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
func the_four_exist_and_ice_is_still_last() -> void:
	var all := EnemyTable.all()
	var by_id := {}
	for k in all.size():
		by_id[all[k].id] = all[k]
	for id in SpawnDirector.MINIBOSS_IDS:
		_check("%s is in the table" % id, by_id.has(id), true)
		if by_id.has(id):
			# Between firewall and ICE: a set-piece, not a boss.
			_check("%s is tougher than a firewall" % id,
				by_id[id].integrity > by_id[&"firewall"].integrity, true)
			_check("%s is weaker than ICE" % id,
				by_id[id].integrity < by_id[&"ice"].integrity, true)
			_check("%s is flippable" % id,
				by_id[id].corruption_threshold < 1e17, true)
	_check("ICE is still last", all[EnemyTable.ICE].id, &"ice")
	_check("and mini-bosses are all above it",
		EnemyTable.ICE, all.size() - 1)
	finished["the_four_exist_and_ice_is_still_last"] = true
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** — insert before `ice`, with glyphs 10–13 added to the shader in the existing style (a doubled diamond for `fork_bomb`, a shield arc for `packet_filter`, a hollow void for `null_ptr`, a jagged burst for `kernel_panic`). Behaviours from the pool: CHARGER, SUPPORT, AMBUSHER, RANGED respectively. Integrity between `firewall` (34) and `ice` (700) — around 150–260, scaled by `hp_mult` at spawn.

- [ ] **Step 4: Verify** — `tools/run_tests.sh --fast`. **Step 5: Commit** — `feat: four mini-boss types`

---

### Task 3: `fork_bomb` splits, after the tick

**Files:** `scripts/run/run.gd`, `tests/test_minibosses.gd`

**Interfaces:** `run._split_gen: PackedInt32Array`, `run._pending_splits: Array`, `SPLIT_GENERATIONS`.

- [ ] **Step 1: Write the failing test**

```gdscript
func splitting_is_bounded_and_deferred() -> void:
	var r := await _fresh_run()
	var idx := _type_index(&"fork_bomb")
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 100.0, 26.0, idx)
	r._spawn_enemy_state(i, 100.0)
	var before: int = r.enemies.count

	r._on_death(i)
	# Deferred: nothing may be spawned inside the drain, which is where _on_death
	# runs. Spawning there pulls entities out from under a pass still
	# adjudicating them.
	_check("nothing spawned during the drain", r.enemies.count, before)
	_check("a split is queued", r._pending_splits.size(), 1)

	r._step9b_splits()
	_check("two children after the tick", r.enemies.count, before + 1)  # parent slot reused
	_check("the queue is drained", r._pending_splits.size(), 0)

	# The bound: three generations, then the leaves die for good. Without it one
	# death is an unbounded cascade that fills the pool.
	var total := 0
	for gen in range(6):
		var queued := r._pending_splits.size()
		for k in r.enemies.count:
			if r.enemies.type_index[k] == idx:
				r._on_death(k)
		r._step9b_splits()
		total += 1
		if r._pending_splits.is_empty() and r.enemies.count == 0:
			break
	_check("the cascade terminates", r.enemies.count < r.MAX_ENEMIES, true)
	r.free()
	finished["splitting_is_bounded_and_deferred"] = true
```

- [ ] **Step 2: Run to verify it fails** — `_pending_splits` is not defined.

- [ ] **Step 3: Implement**

```gdscript
## How many times a fork_bomb may divide. Three generations, then the leaves
## die for good — the leaf check is what stops one death becoming an unbounded
## cascade that fills the enemy pool.
const SPLIT_GENERATIONS := 3

var _split_gen: PackedInt32Array
var _pending_splits: Array = []
```

In `_on_death`, before the shard drop:

```gdscript
	if enemies.type_index[i] == _fork_bomb_index and _split_gen[i] < SPLIT_GENERATIONS:
		# Flagged, not spawned: this runs inside the drain.
		_pending_splits.append([enemies.pos[i], _split_gen[i] + 1,
			_spawn_hp[i] * 0.5])
```

And after `_step9_recycle()` in the tick:

```gdscript
func _step9b_splits() -> void:
	for entry in _pending_splits:
		for k in 2:
			var at: Vector2 = entry[0] + Vector2(randf_range(-30, 30),
				randf_range(-30, 30))
			var hp: float = entry[2]
			var idx := enemies.spawn(terrain.nearest_open(at), Vector2.ZERO, hp,
				20.0, _fork_bomb_index)
			if idx < 0:
				continue        # pool full: drop the child rather than overflow
			_spawn_enemy_state(idx, hp, EnemyTable.Behaviour.CHARGER)
			_split_gen[idx] = entry[1]
	_pending_splits.clear()
```

`_split_gen[i] = 0` belongs in `_spawn_enemy_state` — a recycled slot inheriting generation 3 would refuse to split at all.

- [ ] **Step 4: Verify.** **Step 5: Commit** — `feat: fork_bomb splits, bounded and after the tick`

---

### Task 4: `packet_filter`'s directional armour

**Files:** `scripts/run/run.gd`, `tests/test_minibosses.gd`

- [ ] **Step 1: Write the failing test**

```gdscript
func armour_is_directional() -> void:
	var r := await _fresh_run()
	var idx := _type_index(&"packet_filter")
	var i: int = r.enemies.spawn(Vector2(400, 0), Vector2.ZERO, 200.0, 26.0, idx)
	r._spawn_enemy_state(i, 200.0)
	r.enemies.vel[i] = Vector2(-1, 0) * 40.0        # facing the player, i.e. -x

	# A hit landing on its FRONT is reduced.
	var front := r._facing_scale(i, r.enemies.pos[i] + Vector2(-100, 0))
	var back := r._facing_scale(i, r.enemies.pos[i] + Vector2(100, 0))
	_check("a hit from the front is reduced", front < 0.2, true)
	_check("a hit from behind is not", back, 1.0)
	# The boundary is the half-plane, not an arbitrary cone.
	var side := r._facing_scale(i, r.enemies.pos[i] + Vector2(0, 100))
	_check("a hit from the side is full", side, 1.0)

	# Ordinary enemies are unaffected.
	var j: int = r.enemies.spawn(Vector2(500, 0), Vector2.ZERO, 10.0, 12.0, 0)
	r._spawn_enemy_state(j, 10.0)
	_check("an ordinary enemy has no facing armour",
		r._facing_scale(j, r.enemies.pos[j] + Vector2(-100, 0)), 1.0)
	r.free()
	finished["armour_is_directional"] = true
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement**

```gdscript
const FILTER_FRONT_SCALE := 0.10

## How much of a hit lands, given where it came from.
##
## The first enemy whose POSITION relative to you matters more than your damage:
## flanking it is a manoeuvre rather than a stat check. Facing is its movement
## direction, so it turns as it repositions.
##
## Lands in _hit, where the source position is already known — not in the drain,
## which would have to read facing for every enemy on every hit.
func _facing_scale(i: int, from: Vector2) -> float:
	if enemies.type_index[i] != _packet_filter_index:
		return 1.0
	var facing := enemies.vel[i]
	if facing.length_squared() < 0.01:
		return 1.0
	# The half-plane: anything in front of its shoulders, not a narrow cone.
	if (from - enemies.pos[i]).normalized().dot(facing.normalized()) < 0.0:
		return FILTER_FRONT_SCALE
	return 1.0
```

Apply it in `_hit` where the damage amount is computed, using the shot's origin (the player's position for broadcast/chain/beam, the projectile's position for packets).

- [ ] **Step 4: Verify.** **Step 5: Commit** — `feat: packet_filter takes reduced damage from the front`

---

### Task 5: `null_ptr`'s afterimages, and the dynamic zone overlay

**Files:** `scripts/run/terrain.gd`, `scripts/run/run.gd`, `tests/test_minibosses.gd`

**Interfaces:** `Terrain.add_temp_zone(p, radius, kind, seconds)`, `Terrain.step_temp_zones(dt)`, `Terrain.temp_zone_at(p) -> int`, `Terrain.MAX_TEMP_ZONES`.

- [ ] **Step 1: Write the failing test**

```gdscript
func afterimages_are_bounded_and_expire() -> void:
	var t := Terrain.new(Vector2(-1600, -1000), Vector2(3200, 2000))
	t.generate(4, 1, Vector2.ZERO)
	t.add_temp_zone(Vector2.ZERO, 60.0, Terrain.Kind.HAZARD, 2.0)
	_check("an afterimage is felt", t.temp_zone_at(Vector2(10, 0)),
		Terrain.Kind.HAZARD)
	_check("but not far from it", t.temp_zone_at(Vector2(400, 0)), -1)

	t.step_temp_zones(2.5)
	_check("and it expires", t.temp_zone_at(Vector2(10, 0)), -1)

	# HARD CAP. A long null_ptr fight must stop producing new afterimages
	# rather than growing the list without limit.
	for k in Terrain.MAX_TEMP_ZONES + 20:
		t.add_temp_zone(Vector2(k * 5, 0), 40.0, Terrain.Kind.HAZARD, 99.0)
	_check("the overlay is capped", t.temp_zone_count() <= Terrain.MAX_TEMP_ZONES, true)

	# The BAKED grid is untouched: that is what keeps it a bare array index.
	var before := t.zone.duplicate()
	t.add_temp_zone(Vector2(100, 100), 60.0, Terrain.Kind.HAZARD, 1.0)
	_check("the baked zone grid never changes", t.zone, before)
	finished["afterimages_are_bounded_and_expire"] = true
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** a small parallel-array overlay on `Terrain` (position, radius squared, kind, seconds left), checked after the baked lookup in `run.gd`'s zone pass. `add_temp_zone` drops the request when full rather than growing. Have `null_ptr` call it each time it submerges (in `_ambush`, when the type is `null_ptr`).

- [ ] **Step 4: Verify.** **Step 5: Commit** — `feat: null_ptr leaves damaging afterimages`

---

### Task 6: `kernel_panic`'s line-of-sight pulse

**Files:** `scripts/run/terrain.gd`, `scripts/run/run.gd`, `tests/test_minibosses.gd`

**Interfaces:** `Terrain.has_line_of_sight(a: Vector2, b: Vector2) -> bool`.

- [ ] **Step 1: Write the failing test**

```gdscript
func the_pulse_is_blocked_by_walls() -> void:
	var t := Terrain.new(Vector2(-1600, -1000), Vector2(3200, 2000))
	t.generate(6, 1, Vector2.ZERO)
	t.solid.fill(0)
	_check("open ground sees across itself",
		t.has_line_of_sight(Vector2(-300, 0), Vector2(300, 0)), true)

	# A wall between them blocks it.
	for y in range(-2, 3):
		var c := t.cell_xy(Vector2(0, y * Terrain.CELL))
		t.solid[c.y * t.w + c.x] = 1
	_check("a wall between them blocks it",
		t.has_line_of_sight(Vector2(-300, 0), Vector2(300, 0)), false)
	_check("and it is symmetric",
		t.has_line_of_sight(Vector2(300, 0), Vector2(-300, 0)), false)
	_check("a point sees itself", t.has_line_of_sight(Vector2.ZERO, Vector2.ZERO), true)

	# It must terminate on every seed, however awkward the geometry.
	for s in range(60):
		var u := Terrain.new(Vector2(-1600, -1000), Vector2(3200, 2000))
		u.generate(s, 1, Vector2.ZERO)
		u.has_line_of_sight(Vector2(-1500, -900), Vector2(1500, 900))
	_check("the walk always terminates", true, true)
	finished["the_pulse_is_blocked_by_walls"] = true
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** a DDA walk over the occupancy grid, stepping cell to cell from `a` to `b` and returning false on the first solid cell. Bounded by the cell distance so it cannot loop. Give `kernel_panic` a pulse timer in `_ranged`: on fire, if `has_line_of_sight(pos, player_pos)`, damage the player heavily and draw a bright expanding ring; otherwise nothing. Telegraph the wind-up the way the charger does.

- [ ] **Step 4: Verify.** **Step 5: Commit** — `feat: kernel_panic pulses through line of sight only`

---

### Task 7: The reward, and full verification

**Files:** `scripts/run/run.gd`, `scripts/run/ui.gd`, `tests/test_minibosses.gd`, `README.md`

- [ ] **Step 1: Write the failing test**

```gdscript
func killing_one_offers_a_card() -> void:
	var r := await _fresh_run()
	var idx := _type_index(&"packet_filter")
	var i: int = r.enemies.spawn(Vector2(300, 0), Vector2.ZERO, 100.0, 26.0, idx)
	r._spawn_enemy_state(i, 100.0)
	var salvage_before: int = r.salvage
	var levels_before: int = r.pending_levels
	r._on_death(i)
	_check("it pays salvage", r.salvage > salvage_before, true)
	_check("and offers a card", r.pending_levels, levels_before + 1)

	# Exactly once, even if the death dispatches twice.
	r._on_death(i)
	_check("and only once", r.pending_levels, levels_before + 1)
	r.free()
	finished["killing_one_offers_a_card"] = true
```

- [ ] **Step 2: Run to verify it fails.**

- [ ] **Step 3: Implement** — on a mini-boss death, `salvage += 120` and `pending_levels += 1`, guarded by a per-slot "already rewarded" byte so a re-dispatch cannot pay twice. Name the live mini-boss in the HUD.

- [ ] **Step 4: Full verification** — `tools/run_tests.sh`, and look at a screenshot with a mini-boss on screen. Report the perf number against 3.932 ms; the suspects are the afterimage overlay check (per entity per tick) and the split spawn.

- [ ] **Step 5: Commit** — `feat: mini-boss kills pay salvage and a card`
