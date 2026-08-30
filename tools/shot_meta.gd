extends SceneTree
var frames := 0
func _initialize() -> void:
	SaveGame.use_fresh_state()
	SaveGame.load_state()["salvage"] = 1240
	SaveGame.load_state()["buffs"]["cpu_cycles"] = 3
	SaveGame.load_state()["buffs"]["cooling"] = 1
	SaveGame.load_state()["kills"] = 212
	SaveGame.load_state()["flips"] = 31
	root.add_child(load("res://scenes/main.tscn").instantiate())
func _process(_d: float) -> bool:
	frames += 1
	if frames == 20:
		root.get_texture().get_image().save_png("/tmp/rootkit_meta.png")
		return true
	return false
