extends "res://tools/fps_probe.gd"

## The shared four-player combat probe, with one live frame saved for review.
## godot -s res://tools/fps_entity_designs.gd -- rows5
func _report() -> void:
	DirAccess.make_dir_recursive_absolute("res://.tmp")
	var error := root.get_texture().get_image().save_png("res://.tmp/entity-live.png")
	if error != OK:
		printerr("Could not save live capture: ", error)
	super._report()
