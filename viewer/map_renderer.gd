# The ground and the buildings. With art: dual-grid TileMapLayers from the PixelLab Wang tilesets (ground = water/grass,
# streets = grass/cobble) and one sprite per building; without art: the procedural rectangles of Phase 1.
extends Node2D

const TILE := 16
const KIND_COLORS := {"house": Color("#b98a5a"), "cafe": Color("#c86f4a"), "store": Color("#5a7fb9"), "office": Color("#8a6bb8"), "hall": Color("#4b8a6b"),
	"square": Color("#d9c9a0"), "clinic": Color("#5f9ea0"), "lighthouse": Color("#e8dcc0"), "pier": Color("#a08a6a"), "school": Color("#c9a85a"), "workshop": Color("#7a7a6a")}
const GROUND_COLORS := {".": Color("#6f8f5a"), "#": Color("#8c8a80"), "~": Color("#3f6f9a"), "B": Color("#6a5a4a"), "o": Color("#d9c9a0")}

var map := {}
var art = null           # art_loader
var font: Font
var layers: Array = []   # TileMapLayer nodes
var sprites: Node2D      # building sprites
var labels: Node2D       # names, drawn last

func _ready() -> void:
	sprites = Node2D.new()
	sprites.draw.connect(_draw_buildings)   # procedural buildings must draw above the ground layers (children draw over the parent)
	add_child(sprites)
	labels = Node2D.new()
	labels.draw.connect(_draw_labels)
	add_child(labels)

func set_map(m: Dictionary) -> void:
	map = m
	for l in layers:
		l.queue_free()
	layers.clear()
	for s in sprites.get_children():
		s.queue_free()
	if art and art.has_art():
		_build_ground("ground", func(t: String): return t != "~", false)
		_build_ground("streets", func(t: String): return t == "#" or t == "o", true)
		for b in map.get("buildings", []):
			var t: Texture2D = art.building(str(b.kind), int(b.w), int(b.h))
			if t:
				var s := Sprite2D.new()
				s.texture = t
				s.centered = false
				s.position = Vector2(int(b.x) * TILE, int(b.y) * TILE)
				sprites.add_child(s)
	queue_redraw()
	sprites.queue_redraw()
	labels.queue_redraw()

## dual grid: each rendered tile sits on a corner between four map cells; its four corners are those cells' terrains.
## `upper` says which cells are the set's upper terrain; `sparse` skips all-lower tiles so the layer below shows through.
func _build_ground(name: String, upper: Callable, sparse: bool) -> void:
	var tiles: Dictionary = art.tileset(name)
	if tiles.is_empty():
		return
	var w := int(map.w)
	var h := int(map.h)
	var s: String = map.tiles
	var ts := TileSet.new()
	ts.tile_size = Vector2i(TILE, TILE)
	var ids := {}
	for k in tiles:
		var src := TileSetAtlasSource.new()
		src.texture = tiles[k]
		src.texture_region_size = Vector2i(TILE, TILE)
		src.create_tile(Vector2i.ZERO)
		ids[k] = ts.add_source(src)
	var layer := TileMapLayer.new()
	layer.tile_set = ts
	layer.position = Vector2(-TILE / 2.0, -TILE / 2.0)
	add_child(layer)
	move_child(layer, layers.size())   # ground layers sit under sprites and labels
	layers.append(layer)
	for y in range(h + 1):
		for x in range(w + 1):
			var up: Array = []
			for c in [["NW", x - 1, y - 1], ["NE", x, y - 1], ["SW", x - 1, y], ["SE", x, y]]:
				var cx: int = clampi(c[1], 0, w - 1)
				var cy: int = clampi(c[2], 0, h - 1)
				if upper.call(s[cy * w + cx]):
					up.append(c[0])
			var key := "+".join(up) if up.size() > 0 else "none"
			if sparse and up.is_empty():
				continue
			if not ids.has(key):
				key = "none" if ids.has("none") else str(ids.keys()[0])
			layer.set_cell(Vector2i(x, y), ids[key], Vector2i.ZERO)

func _draw() -> void:
	if map.is_empty():
		return
	var w := int(map.w)
	var h := int(map.h)
	if layers.is_empty():   # no ground art: procedural tiles
		var tiles: String = map.tiles
		for y in h:
			for x in w:
				var t := tiles[y * w + x]
				var col: Color = GROUND_COLORS.get(t, Color.MAGENTA)
				if t == "." and (x + y) % 2 == 0:
					col = col.darkened(0.04)
				if t == "~" and (x * 7 + y * 3) % 5 == 0:
					col = col.lightened(0.08)
				draw_rect(Rect2(x * TILE, y * TILE, TILE, TILE), col)
	draw_rect(Rect2(0, 0, w * TILE, h * TILE), Color(1, 1, 1, 0.5), false, 2.0)

func _draw_buildings() -> void:
	for b in map.get("buildings", []):
		if art and art.building(str(b.kind), int(b.w), int(b.h)):
			continue   # has a sprite
		var r := Rect2(int(b.x) * TILE, int(b.y) * TILE, int(b.w) * TILE, int(b.h) * TILE)
		var col: Color = KIND_COLORS.get(b.kind, Color("#8a7a6a"))
		if b.get("open", false):
			sprites.draw_rect(r, col.darkened(0.1), false, 2.0)
		else:
			sprites.draw_rect(r, col)
			sprites.draw_rect(Rect2(r.position, Vector2(r.size.x, 4)), col.darkened(0.3))
			var d: Array = b.door
			sprites.draw_rect(Rect2(int(d[0]) * TILE + 5, int(d[1]) * TILE, 6, 4), Color("#3a2a1a"))

func _draw_labels() -> void:
	if map.is_empty() or font == null:
		return
	for b in map.buildings:
		labels.draw_string(font, Vector2(int(b.x) * TILE + 2, int(b.y) * TILE - 3), b.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, 0.9))
	for s in map.streets:
		labels.draw_string(font, Vector2(int(s.x) * TILE + 4, int(s.y) * TILE + 12), s.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.15, 0.15, 0.15, 0.7))
