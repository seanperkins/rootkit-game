extends SceneTree

const Music = preload("res://scripts/audio/music.gd")
var failures := 0
var completed := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		print("  FAIL  ", label)
		failures += 1

func _initialize() -> void:
	SaveGame.use_test_paths()
	await process_frame
	bank_and_harmony()
	await events_and_lifecycle()
	check("both cases completed", completed == 2)
	print("  PASS — ensemble harmony, event and lifecycle behavior" if failures == 0 else "  FAIL — %d assertions" % failures)
	quit(0 if failures == 0 else 1)

func bank_and_harmony() -> void:
	var bank := Synth.build_bank()
	var feel := Feel.new()
	for index in Feel.VOICE_COUNT:
		check("every emitted voice resolves", bank.has(Feel.VOICE_IDS[index]))
		feel.emit_voice(index)
		feel.emit_voice(index)
		for root_degree in Music.PROGRESSION:
			if index != Feel.VOICE_CHASE:
				check("pitched voice stays in scale", Music.SCALE.has(posmod(Music.semitones(root_degree + Music.VOICE_DEGREES[index]), 12)))
			for stream in bank[Feel.VOICE_IDS[index]]:
				check("rendered voice clears before fastest retrigger", stream.get_length() / Music.voice_pitch(index, root_degree) < 60.0 / Music.BPM_HOT * 0.5 - 0.025)
	check("first wins within each subdivision", feel.drain_voice() == (1 << Feel.VOICE_COUNT) - 1)
	check("drain discards all pending events", feel.drain_voice() == 0)
	for example in [[0, 3, 7], [5, 4, 7], [4, 3, 6]]:
		var root_degree: int = example[0]
		check("triad third", Music.semitones(root_degree + 2) - Music.semitones(root_degree) == example[1])
		check("triad fifth", Music.semitones(root_degree + 4) - Music.semitones(root_degree) == example[2])
	completed += 1

func events_and_lifecycle() -> void:
	var g: Node2D = load("res://scenes/run.tscn").instantiate()
	g.external_drive = true
	root.add_child(g)
	await process_frame
	var music: Node
	for child in g.get_children():
		if child.get_script() == Music: music = child
	check("music bound", music != null)
	var before: int = g._state_hash()
	g.feel.emit_voice(Feel.VOICE_CHASE)
	g._chase_jostling.fill(1)
	g._flank_arcing.fill(1)
	check("audio producer state cannot affect checksum", before == g._state_hash())
	g.user_paused = true
	check("solo pause clears pending edges immediately", g.feel.voice_pending == 0 and g._chase_jostling[0] == 0 and not music.ensemble_allowed())
	g.feel.emit_voice(Feel.VOICE_PLAYER0)
	g.user_paused = false
	check("resume clears sub-step stale event", g.feel.voice_pending == 0)
	Music.apply_volume(0)
	g.feel.emit_voice(Feel.VOICE_PLAYER0)
	Music.apply_volume(0.5)
	check("mute then unmute before a beat cannot replay", g.feel.voice_pending == 0)
	g._session.role = NetworkSession.Role.HOST
	g.user_paused = true
	check("co-op local pause leaves shared music active", music.ensemble_allowed())
	g.user_paused = false
	g.paused = true
	g.feel.emit_voice(Feel.VOICE_SUPPORT)
	music._on_step()
	check("shared offer drains without playing ensemble", g.feel.voice_pending == 0 and not music._ensemble[Feel.VOICE_SUPPORT].playing)
	g.paused = false
	music._sync_ensemble()
	g.feel.emit_voice(Feel.VOICE_SUPPORT)
	music._on_step()
	check("eligible note starts on beat", music._ensemble[Feel.VOICE_SUPPORT].playing)
	check("catch-up mask has no backlog", g.feel.drain_voice() == 0)
	g._target_slot = 0
	g.feel.drain_voice()
	g._fire_hostile(Vector2(100, 0))
	check("successful hostile shot emits ranged voice", g.feel.drain_voice() & (1 << Feel.VOICE_RANGED) != 0)
	while g.hostiles.count < g.MAX_HOSTILES: g.hostiles.spawn(Vector2.ZERO, Vector2.ZERO, 1, 1, 0)
	g._fire_hostile(Vector2(100, 0))
	check("dropped hostile shot is silent", g.feel.drain_voice() == 0)
	var ti := EnemyTable.index_of(&"sentinel")
	var i: int = g.enemies.spawn(Vector2(100, 0), Vector2.ZERO, 46, 12, ti)
	g._spawn_enemy_state(i, 46)
	g._charge(i, 46, Vector2(100, 0), 0)
	check("windup does not emit launch note", g.feel.drain_voice() == 0)
	g._charge(i, 46, Vector2(100, 0), g.CHARGE_WINDUP + 0.01)
	check("dash launch emits charger note", g.feel.drain_voice() & (1 << Feel.VOICE_CHARGER) != 0)
	g._ai_phase[i] = g.AM_SURFACING
	g._ai_timer[i] = 0
	g._ambush(i, 46, Vector2(100, 0), 0.01)
	check("completed surfacing emits ambusher note", g.feel.drain_voice() & (1 << Feel.VOICE_AMBUSHER) != 0)
	g.player_vel[0] = Vector2(220, 0)
	g._flank(i, 46, Vector2(100, 0))
	check("flank edge emits", g.feel.drain_voice() & (1 << Feel.VOICE_FLANKER) != 0)
	g._flank(i, 46, Vector2(100, 0))
	check("sustained arc does not retrigger every tick", g.feel.drain_voice() == 0)
	g.feel.emit_voice(Feel.VOICE_CHASE)
	g.won = true
	music._process(0)
	check("run end clears before early return", g.feel.voice_pending == 0 and not music._ensemble[Feel.VOICE_SUPPORT].playing)
	g.free()
	completed += 1
