# Map = tiles rasterized from water/street/building rects. Static functions over the map Dictionary.
# Tiles: '.' grass  '#' street  '~' water  'B' building (blocked)  'o' open place (walkable)
extends RefCounted

const Schema = preload("res://world/schema.gd")
const ENTER_COST := {"#": 1, ".": 3, "o": 2}

static func idx(m: Dictionary, x: int, y: int) -> int:
	return y * int(m.w) + x

static func in_bounds(m: Dictionary, x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < int(m.w) and y < int(m.h)

static func tile(m: Dictionary, x: int, y: int) -> String:
	if not in_bounds(m, x, y):
		return "~"
	return m.tiles[idx(m, x, y)]

static func walkable(m: Dictionary, x: int, y: int) -> bool:
	return in_bounds(m, x, y) and ENTER_COST.has(tile(m, x, y))

static func _fill(m: Dictionary, chars: PackedStringArray, r: Dictionary, ch: String) -> void:
	for y in range(int(r.y), int(r.y) + int(r.h)):
		for x in range(int(r.x), int(r.x) + int(r.w)):
			if in_bounds(m, x, y):
				chars[idx(m, x, y)] = ch

static func rebuild(m: Dictionary) -> void:
	var n := int(m.w) * int(m.h)
	var chars := PackedStringArray()
	chars.resize(n)
	chars.fill(".")
	for r in m.water:
		_fill(m, chars, r, "~")
	for r in m.streets:
		_fill(m, chars, r, "#")
	for b in m.buildings:
		_fill(m, chars, b, "o" if b.get("open", false) else "B")
	m.tiles = "".join(chars)
	for b in m.buildings:
		b.door = door_of(m, b)

# The door is the walkable tile nearest the bottom-centre of the footprint; open places use their centre.
static func door_of(m: Dictionary, b: Dictionary) -> Array:
	if b.get("open", false):
		return [int(b.x) + int(b.w) / 2, int(b.y) + int(b.h) / 2]
	var cx := int(b.x) + int(b.w) / 2
	var candidates := [[cx, int(b.y) + int(b.h)], [cx, int(b.y) - 1], [int(b.x) - 1, int(b.y) + int(b.h) / 2], [int(b.x) + int(b.w), int(b.y) + int(b.h) / 2]]
	for c in candidates:
		if walkable(m, c[0], c[1]):
			return c
	# perimeter scan
	for y in range(int(b.y) - 1, int(b.y) + int(b.h) + 1):
		for x in range(int(b.x) - 1, int(b.x) + int(b.w) + 1):
			if walkable(m, x, y):
				return [x, y]
	return [cx, int(b.y) + int(b.h)]

static func building(m: Dictionary, id: int) -> Dictionary:
	for b in m.buildings:
		if int(b.id) == id:
			return b
	return {}

static func first_of_kind(m: Dictionary, kind: String) -> Dictionary:
	for b in m.buildings:
		if b.kind == kind or b.name.to_lower() == kind.to_lower():
			return b
	return {}

static func inside(b: Dictionary, x: int, y: int) -> bool:
	return x >= int(b.x) and y >= int(b.y) and x < int(b.x) + int(b.w) and y < int(b.y) + int(b.h)

# Dijkstra with a bucket queue (costs are 1..3). ponytail: whole-grid arrays per call; fine under ~200x200.
static func find_path(m: Dictionary, from: Array, to: Array) -> Array:
	var w := int(m.w)
	var h := int(m.h)
	var n := w * h
	if not walkable(m, to[0], to[1]) or not in_bounds(m, from[0], from[1]):
		return []
	var start := idx(m, from[0], from[1])
	var goal := idx(m, to[0], to[1])
	if start == goal:
		return []
	var dist := PackedInt32Array()
	dist.resize(n)
	dist.fill(0x3fffffff)
	var prev := PackedInt32Array()
	prev.resize(n)
	prev.fill(-1)
	dist[start] = 0
	var buckets: Array = [[start]]
	var d := 0
	var found := false
	while d < buckets.size():
		var bucket: Array = buckets[d]
		var i := 0
		while i < bucket.size():
			var cur: int = bucket[i]
			i += 1
			if dist[cur] != d:
				continue
			if cur == goal:
				found = true
				break
			var cx := cur % w
			var cy := int(cur / w)
			for step in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
				var nx: int = cx + step[0]
				var ny: int = cy + step[1]
				if not in_bounds(m, nx, ny):
					continue
				var t: String = m.tiles[ny * w + nx]
				if not ENTER_COST.has(t):
					continue
				var nd: int = d + ENTER_COST[t]
				var ni := ny * w + nx
				if nd < dist[ni]:
					dist[ni] = nd
					prev[ni] = cur
					while buckets.size() <= nd:
						buckets.append([])
					buckets[nd].append(ni)
		if found:
			break
		d += 1
	if not found:
		return []
	var path: Array = []
	var cur := goal
	while cur != start and cur != -1:
		path.append([cur % w, int(cur / w)])
		cur = prev[cur]
	path.reverse()
	return path

# A random walkable tile inside an open place, or the door for a closed one.
static func target_tile(m: Dictionary, b: Dictionary, rng: RandomNumberGenerator) -> Array:
	if b.is_empty():
		return [-1, -1]
	if b.get("open", false):
		for _i in 8:
			var x: int = int(b.x) + rng.randi_range(0, int(b.w) - 1)
			var y: int = int(b.y) + rng.randi_range(0, int(b.h) - 1)
			if walkable(m, x, y):
				return [x, y]
	return [int(b.door[0]), int(b.door[1])]

static func rect_free(m: Dictionary, x: int, y: int, w: int, h: int) -> bool:
	# footprint plus a one-tile margin must be grass
	for yy in range(y - 1, y + h + 1):
		for xx in range(x - 1, x + w + 1):
			if not in_bounds(m, xx, yy) or tile(m, xx, yy) != ".":
				return false
	return true

# Finds a free footprint whose bottom edge sits one tile above a street (a door onto the street).
static func find_lot(m: Dictionary, w: int, h: int, rng: RandomNumberGenerator) -> Array:
	var spots: Array = []
	for s in m.streets:
		if int(s.w) >= int(s.h):  # horizontal street: lots above and below
			for x in range(int(s.x), int(s.x) + int(s.w) - w + 1):
				if rect_free(m, x, int(s.y) - h - 1, w, h):
					spots.append([x, int(s.y) - h - 1])
				if rect_free(m, x, int(s.y) + int(s.h) + 1, w, h):
					spots.append([x, int(s.y) + int(s.h) + 1])
		else:  # vertical: lots left and right
			for y in range(int(s.y), int(s.y) + int(s.h) - h + 1):
				if rect_free(m, int(s.x) - w - 1, y, w, h):
					spots.append([int(s.x) - w - 1, y])
				if rect_free(m, int(s.x) + int(s.w) + 1, y, w, h):
					spots.append([int(s.x) + int(s.w) + 1, y])
	if spots.is_empty():
		return []
	return spots[rng.randi_range(0, spots.size() - 1)]

# Grows the town southward: taller map, Lantern Row extended, a new cross street every `by` rows.
static func expand_south(m: Dictionary, by: int, tick: int) -> void:
	var old_h := int(m.h)
	m.h = old_h + by
	for w in m.water:
		if int(w.y) + int(w.h) >= old_h:
			w.h = int(w.h) + by
	for s in m.streets:
		if int(s.h) > int(s.w) and int(s.y) + int(s.h) >= old_h - 2:
			s.h = int(s.h) + by
	var n: int = m.streets.size()
	var vertical := {}
	for s in m.streets:
		if int(s.h) > int(s.w):
			vertical = s
			break
	var cross := {"name": "%s Cross" % ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth", "Ninth", "Tenth"][min(n, 9)],
		"x": 2, "y": old_h + by - 4, "w": max(8, int(m.w) - 8), "h": 2, "built_tick": tick}
	if not vertical.is_empty():
		cross.x = max(2, int(vertical.x) - 16)
		cross.w = min(int(m.w) - 8 - cross.x, 34)
	for k in Schema.STREET:
		if not cross.has(k):
			cross[k] = Schema.STREET[k]
	m.streets.append(cross)
	rebuild(m)

static func add_building(m: Dictionary, b: Dictionary) -> void:
	for k in Schema.BUILDING:
		if not b.has(k):
			b[k] = Schema.BUILDING[k].duplicate(true) if typeof(Schema.BUILDING[k]) in [TYPE_ARRAY, TYPE_DICTIONARY] else Schema.BUILDING[k]
	m.buildings.append(b)
	rebuild(m)

static func house_capacity(m: Dictionary) -> int:
	var cap := 0
	for b in m.buildings:
		if b.kind == "house":
			cap += int(b.capacity)
	return cap
