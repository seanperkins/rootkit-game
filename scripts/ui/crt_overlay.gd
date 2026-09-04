extends CanvasLayer

## A restrained, always-on-top CRT pass: thin scanlines and a soft vignette
## over the whole game, menu and run alike. An autoload — like Updater — so
## it survives the menu <-> run scene swap instead of being rebuilt, and
## re-added, per scene.

func _ready() -> void:
	# Above every CanvasLayer either scene builds (ui.gd's default is 1).
	layer = 100
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.color = Color(1.0, 1.0, 1.0, 1.0)
	var mat := ShaderMaterial.new()
	mat.shader = load("res://shaders/crt.gdshader")
	rect.material = mat
	add_child(rect)
