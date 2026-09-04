class_name TerminalStyle extends RefCounted

## Shared terminal chrome for every screen: the menu, the HUD, settings.
## Built in code — the repo ships no image assets and no font files (see
## shaders/glyph.gdshader's identical rule for enemy glyphs) — so "font"
## here means SystemFont, a live OS lookup with zero bytes in the repo, and
## "border" means a StyleBoxFlat with sharp corners rather than a texture.
##
## Godot's own StyleBoxFlat already defaults to sharp corners, and this
## project's hand-built panels (ui.gd's _panel, the card/pause/end scrims)
## already use it — the one widget nobody had ever styled is Button (and
## LineEdit), which fall back to the engine's stock rounded default theme.
## That mismatch, not the palette or the layout, is what read as generic
## rather than terminal. One Theme fixes it everywhere at once: apply it to
## a screen's root Control and it cascades to every descendant, the same
## way CSS inheritance would — no per-widget call site needs to change.

const FG := Color(0.55, 1.0, 0.72)
const DIM := Color(0.32, 0.58, 0.45)
const HOT := Color(1.0, 0.72, 0.35)
const BG := Color(0.016, 0.031, 0.027)

static var _font: SystemFont
static var _theme: Theme

## The OS's installed monospace font, by name — SF Mono/Menlo on macOS,
## Consolas on Windows, DejaVu/the "monospace" fontconfig alias on Linux.
## No file ships in the repo; SystemFont resolves it at runtime and falls
## back to the engine's built-in proportional font if none of the names
## resolve (an odd install, a future web export) rather than failing — the
## ASCII-bar styling already tolerated that silently, so this only makes
## the common case actually align into columns.
static func mono_font() -> SystemFont:
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = ["SF Mono", "Menlo", "Consolas", "DejaVu Sans Mono", "monospace"]
	return _font

## A sharp-cornered bordered box — the one shape every terminal window in
## this game should share. corner_radius is already 0 by default; set
## explicitly so a future StyleBoxFlat default change can't round it.
static func panel_style(border: Color, bg_color: Color = BG, border_w: int = 1) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.border_color = border
	sb.set_border_width_all(border_w)
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(10)
	return sb

## The one Theme every screen root applies. Button and LineEdit get full
## state coverage (normal/hover/focus/pressed/disabled) because Godot's
## default theme otherwise supplies its own rounded grey box the instant a
## StyleBoxFlat override is absent for any one state — a Theme that styled
## only "normal" would look sharp at rest and generic on hover.
static func build_theme() -> Theme:
	if _theme != null:
		return _theme
	var theme := Theme.new()
	theme.default_font = mono_font()

	var normal := panel_style(DIM)
	var hover := panel_style(FG, Color(FG.r, FG.g, FG.b, 0.08))
	var focus := panel_style(HOT, Color(HOT.r, HOT.g, HOT.b, 0.12), 2)
	var pressed := panel_style(HOT, Color(HOT.r, HOT.g, HOT.b, 0.22), 2)
	var disabled := panel_style(Color(DIM.r, DIM.g, DIM.b, 0.35), Color(BG.r, BG.g, BG.b, 0.6))

	for type in ["Button", "LineEdit"]:
		theme.set_stylebox("normal", type, normal)
		theme.set_stylebox("hover", type, hover)
		theme.set_stylebox("focus", type, focus)
		theme.set_stylebox("pressed", type, pressed)
		theme.set_stylebox("read_only", type, disabled)
		theme.set_stylebox("disabled", type, disabled)
		theme.set_color("font_color", type, FG)
		theme.set_color("font_hover_color", type, FG)
		theme.set_color("font_focus_color", type, HOT)
		theme.set_color("font_pressed_color", type, HOT)
		theme.set_color("font_disabled_color", type, Color(DIM.r, DIM.g, DIM.b, 0.5))
	# LineEdit has no "pressed" state and uses "caret_color" instead of a
	# pressed font color; harmless to set both above; add what Button lacks.
	theme.set_color("caret_color", "LineEdit", HOT)
	theme.set_color("selection_color", "LineEdit", Color(HOT.r, HOT.g, HOT.b, 0.35))

	_theme = theme
	return theme
