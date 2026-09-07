# One citizen on the map: an AnimatedSprite2D (idle_/walk_ × south/north/east/west from PixelLab) when art exists,
# the Phase 1 procedural figure otherwise. Moves toward the tile the server last reported at one tile per tick,
# so a walking citizen glides instead of jumping; facing comes from the server (M6) or from the movement.
extends Node2D

const TILE := 16
const SPEED := TILE * 1.15   # px/s: a hair faster than one tile per tick so it never lags a step behind

var data := {}
var target := Vector2.ZERO
var facing := "south"
var moving := false
var inside := false   # in a closed building: out of sight, listed under the building's name instead
var anim: AnimatedSprite2D
var bubble: Label
var font: Font

static func tile_pos(c: Dictionary) -> Vector2:
	return Vector2(int(c.x) * TILE + TILE / 2.0, int(c.y) * TILE + TILE / 2.0)

func setup(c: Dictionary, sf: SpriteFrames, f: Font) -> void:
	data = c
	font = f
	position = tile_pos(c)
	target = position
	if sf:
		anim = AnimatedSprite2D.new()
		anim.sprite_frames = sf
		anim.position = Vector2(0, -10)   # feet on the tile centre
		anim.play("idle_south")
		add_child(anim)
	bubble = Label.new()
	bubble.position = Vector2(-70, -46)
	bubble.custom_minimum_size = Vector2(140, 0)
	bubble.autowrap_mode = TextServer.AUTOWRAP_WORD
	bubble.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	bubble.add_theme_font_size_override("font_size", 9)
	bubble.add_theme_color_override("font_color", Color.BLACK)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 0.94, 0.95)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	bubble.add_theme_stylebox_override("normal", sb)
	bubble.visible = false
	add_child(bubble)
	apply(c)

func apply(c: Dictionary) -> void:
	data.merge(c, true)
	target = tile_pos(data)
	if position.distance_to(target) > TILE * 6:   # teleport (restore, catch-up) rather than glide across town
		position = target
	visible = data.get("alive", true) and not inside
	if data.has("facing"):
		facing = str(data.facing)
	var text := str(data.get("bubble", ""))
	bubble.visible = text != ""
	bubble.text = text
	if anim == null:
		queue_redraw()

func set_inside(v: bool) -> void:
	inside = v
	visible = data.get("alive", true) and not inside

func _process(delta: float) -> void:
	var d := target - position
	moving = d.length() > 0.5 or bool(data.get("moving", false))
	if moving:
		if not data.has("facing"):
			facing = ("east" if d.x > 0 else "west") if absf(d.x) > absf(d.y) else ("south" if d.y > 0 else "north")
		position = position.move_toward(target, delta * SPEED)
	if anim:
		var want := ("walk_" if moving else "idle_") + facing
		if anim.animation != want and anim.sprite_frames.has_animation(want):
			anim.play(want)

func _draw() -> void:
	if anim == null:
		var col := Color(str(data.get("color", "#c9a86b")))
		var kind := int(data.get("sprite", 0))
		draw_circle(Vector2(0, 6), 6.5, Color(0, 0, 0, 0.25))
		draw_rect(Rect2(-4, -2, 8, 9), col)
		draw_circle(Vector2(0, -6), 4.0, Color("#e9c9a8") if kind % 2 == 0 else Color("#c9a080"))
		if kind >= 2:
			draw_rect(Rect2(-4, -10, 8, 3), col.darkened(0.4))
	if font:
		var col := Color(0.86, 0.78, 1.0, 0.95) if data.get("visitor", false) else Color(1, 1, 1, 0.95)
		draw_string(font, Vector2(-30, 18), str(data.get("name", "")).get_slice(" ", 0), HORIZONTAL_ALIGNMENT_CENTER, 60, 8, col)
