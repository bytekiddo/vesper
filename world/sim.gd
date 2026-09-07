# The world. State is a plain Dictionary (== the checkpoint). Tier 1 runs here every tick, deterministically:
# every random draw comes from rng_for(state, tick, salt). Tier 2 is requested through `brain` (a Callable)
# and its results are applied through cognition.gd at a recorded tick.
extends RefCounted

const Clock = preload("res://kernel/clock.gd")
const Filter = preload("res://kernel/content_filter.gd")
const Schema = preload("res://world/schema.gd")
const Map = preload("res://world/map.gd")
const Memory = preload("res://world/memory.gd")

static var rules: Dictionary = {}

static func R() -> Dictionary:
	if rules.is_empty():
		load_rules()
	return rules

static func load_rules() -> void:
	var parsed = JSON.parse_string(FileAccess.get_file_as_string("res://world/rules.json"))
	rules = parsed if typeof(parsed) == TYPE_DICTIONARY else {}

static func imp(kind: String) -> int:
	return int(R().get("importance", {}).get(kind, 3))

static func rng_for(state: Dictionary, tick: int, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("%d:%d:%d" % [int(state.seed), tick, salt])
	return rng

static func index(state: Dictionary) -> Dictionary:
	var out := {}
	for c in state.citizens:
		out[int(c.id)] = c
	return out

static func citizen(state: Dictionary, id: int) -> Dictionary:
	for c in state.citizens:
		if int(c.id) == id:
			return c
	return {}

static func alive(state: Dictionary) -> Array:
	return state.citizens.filter(func(c): return c.alive)

# ---------------------------------------------------------------- seed
static func new_from_seed(path: String = "res://world/seed.json") -> Dictionary:
	var seed_data: Dictionary = preload("res://kernel/checkpoint.gd").fix_numbers(JSON.parse_string(FileAccess.get_file_as_string(path)))
	var state: Dictionary = Schema.STATE.duplicate(true)
	state.seed = int(seed_data.get("seed", 7))
	state.map = Schema.MAP.duplicate(true)
	for k in ["w", "h", "water", "streets", "buildings"]:
		state.map[k] = seed_data.map[k]
	for s in state.map.streets:
		Schema_merge(s, Schema.STREET)
	for b in state.map.buildings:
		Schema_merge(b, Schema.BUILDING)
	Map.rebuild(state.map)
	for cd in seed_data.citizens:
		var c: Dictionary = Schema.CITIZEN.duplicate(true)
		for k in cd:
			c[k] = cd[k]
		c.age = float(cd.age)
		c.routine = R().routines.get(cd.get("routine", "default"), R().routines.default).duplicate(true)
		var home := Map.building(state.map, int(c.home))
		c.x = int(home.door[0])
		c.y = int(home.door[1])
		c.place = int(c.home)
		home.residents.append(int(c.id))
		state.citizens.append(c)
	for r in seed_data.get("relationships", []):
		var a := citizen(state, int(r[0]))
		if not a.is_empty():
			a.relationships[str(int(r[1]))] = {"kind": r[2], "score": float(r[3]), "note": r[4]}
	for id_s in seed_data.get("first_memories", {}):
		var c := citizen(state, int(id_s))
		for m in seed_data.first_memories[id_s]:
			Memory.add(c, 0, m[0], m[1], int(m[2]))
	state.next_id = 100
	state.rules_hash = str(hash(JSON.stringify(R())))
	return state

static func Schema_merge(d: Dictionary, dflt: Dictionary) -> void:
	for k in dflt:
		if not d.has(k):
			d[k] = dflt[k].duplicate(true) if typeof(dflt[k]) in [TYPE_ARRAY, TYPE_DICTIONARY] else dflt[k]

# ---------------------------------------------------------------- helpers
static func resolve_place(state: Dictionary, c: Dictionary, place: String) -> Dictionary:
	match place:
		"home":
			return Map.building(state.map, int(c.home))
		"work":
			var w := Map.building(state.map, int(c.work))
			return w if not w.is_empty() else Map.first_of_kind(state.map, "square")
	var b := Map.first_of_kind(state.map, place)
	return b if not b.is_empty() else Map.building(state.map, int(c.home))

static func category(action: String) -> String:
	var a := action.to_lower()
	if a.find("sleep") >= 0 or a.find("nap") >= 0 or a.find("rest") >= 0 or a.find("waking") >= 0:
		return "resting"
	if a.find("eat") >= 0 or a.find("lunch") >= 0 or a.find("supper") >= 0 or a.find("breakfast") >= 0 or a.find("tea") >= 0:
		return "eating"
	if a.find("work") >= 0 or a.find("serv") >= 0 or a.find("fir") >= 0 or a.find("polish") >= 0 or a.find("check") >= 0 or a.find("light") >= 0 or a.find("mend") >= 0 or a.find("buy") >= 0 or a.find("stock") >= 0 or a.find("draft") >= 0 or a.find("less") >= 0:
		return "working"
	return "idle"

static func current_block(blocks: Array, minute: int) -> int:
	var best := -1
	for i in blocks.size():
		if Clock.hhmm_to_minute(str(blocks[i].get("at", "00:00"))) <= minute:
			best = i
	if best == -1 and blocks.size() > 0:
		best = blocks.size() - 1
	return best

static func cap(s: String) -> String:
	return s.left(1).to_upper() + s.substr(1) if s.length() > 0 else s

static func pick(arr: Array, rng: RandomNumberGenerator):
	return arr[rng.randi_range(0, arr.size() - 1)] if arr.size() > 0 else null

static func add_event(state: Dictionary, tick: int, text: String, who: Array, importance: int) -> Dictionary:
	var e := {"t": tick, "text": text, "who": who, "imp": importance}
	state.events.append(e)
	while state.events.size() > 200:
		state.events.remove_at(0)
	return e

static func relate(c: Dictionary, other_id: int, kind: String, delta: float, note: String = "") -> void:
	var key := str(other_id)
	if not c.relationships.has(key):
		c.relationships[key] = {"kind": kind, "score": 0.1, "note": note}
	var r: Dictionary = c.relationships[key]
	r.score = clampf(float(r.score) + delta, -1.0, 1.0)
	if note != "":
		r.note = note
	if kind != "" and r.kind in ["", "stranger", "acquaintance"]:
		r.kind = kind

static func place_name(state: Dictionary, c: Dictionary) -> String:
	var b := Map.building(state.map, int(c.place))
	return b.name if not b.is_empty() else "the street"

static func free_house(state: Dictionary) -> Dictionary:
	for b in state.map.buildings:
		if b.kind == "house" and b.residents.size() < int(b.capacity):
			return b
	return {}

static func housing_shortfall(state: Dictionary) -> int:
	var slack := int(R().get("growth", {}).get("housing_slack", 1))
	return alive(state).size() + slack - Map.house_capacity(state.map)

# ---------------------------------------------------------------- citizens
static func make_citizen(state: Dictionary, rng: RandomNumberGenerator, tick: int, opts: Dictionary = {}) -> Dictionary:
	var c: Dictionary = Schema.CITIZEN.duplicate(true)
	var names: Dictionary = R().get("names", {})
	var used := {}
	for o in state.citizens:
		used[o.name] = true
	var nm := ""
	for _i in 50:
		nm = "%s %s" % [pick(names.get("first", ["Ada"]), rng), pick(names.get("last", ["Salt"]), rng)]
		if not used.has(nm):
			break
	c.id = int(state.next_id)
	state.next_id = int(state.next_id) + 1
	c.name = opts.get("name", nm)
	c.age = float(opts.get("age", rng.randi_range(19, 60)))
	c.pronouns = opts.get("pronouns", pick(["she/her", "he/him", "they/them"], rng))
	c.occupation = opts.get("occupation", pick(R().get("occupations", ["fisher"]), rng))
	c.innate = opts.get("innate", "%s, %s" % [pick(R().get("innate_traits", ["patient"]), rng), pick(R().get("innate_traits", ["curious"]), rng)])
	c.learned = opts.get("learned", "new to Vesper; works as a %s" % c.occupation)
	c.lifestyle = opts.get("lifestyle", "keeps ordinary hours and an eye on the water")
	c.currently = opts.get("currently", "finding their feet")
	c.color = opts.get("color", Color.from_hsv(rng.randf(), 0.45, 0.8).to_html(false))
	c.sprite = rng.randi_range(0, 3)
	c.routine = R().routines.get(opts.get("routine", "default"), R().routines.default).duplicate(true)
	c.arrived_tick = tick
	c.parents = opts.get("parents", [])
	var home: Dictionary = Map.building(state.map, int(opts.get("home", 0)))
	if home.is_empty():
		home = free_house(state)
	if home.is_empty():
		home = build_house(state, rng, tick)
	if home.is_empty():
		home = Map.first_of_kind(state.map, "square")
	home.residents.append(c.id)
	c.home = int(home.id)
	var work: Dictionary = Map.building(state.map, int(opts.get("work", 0)))
	if work.is_empty():
		var opts_w: Array = state.map.buildings.filter(func(b): return b.kind not in ["house", "square", "pier"])
		work = pick(opts_w, rng) if opts_w.size() > 0 else home
	c.work = int(work.id)
	c.x = int(home.door[0])
	c.y = int(home.door[1])
	c.place = c.home
	if c.age < 6.0:
		c.routine = [{"at": "00:00", "place": "home", "action": "being small"}]
	elif c.age < 18.0:
		c.work = int(Map.first_of_kind(state.map, "hall").get("id", c.home))
		c.occupation = "child"
	state.citizens.append(c)
	return c

static func build_house(state: Dictionary, rng: RandomNumberGenerator, tick: int) -> Dictionary:
	var g: Dictionary = R().get("growth", {})
	var w := int(g.get("house_w", 3))
	var h := int(g.get("house_h", 2))
	var lot := Map.find_lot(state.map, w, h, rng)
	if lot.is_empty():
		if int(state.map.h) + int(g.get("expand_by", 8)) > int(g.get("max_side", 200)):
			return {}
		Map.expand_south(state.map, int(g.get("expand_by", 8)), tick)
		lot = Map.find_lot(state.map, w, h, rng)
		if lot.is_empty():
			return {}
	var names: Dictionary = R().get("names", {})
	var b := {"id": int(state.next_id), "name": "%s House" % pick(names.get("last", ["New"]), rng), "kind": "house",
		"x": lot[0], "y": lot[1], "w": w, "h": h, "capacity": 3, "built_tick": tick, "note": "Built when the town ran out of beds."}
	state.next_id = int(state.next_id) + 1
	Map.add_building(state.map, b)
	state.map_version = int(state.map_version) + 1
	add_event(state, tick, "A new house went up: %s." % b.name, [], imp("event"))
	return b

static func kill(state: Dictionary, c: Dictionary, tick: int, how: String) -> void:
	c.alive = false
	c.conv = {}
	c.action = how
	var home := Map.building(state.map, int(c.home))
	if not home.is_empty():
		home.residents.erase(int(c.id))
	for o in alive(state):
		if o.relationships.has(str(int(c.id))):
			Memory.add(o, tick, "event", "%s %s. I will not see them again." % [c.name, how], imp("death" if how.begins_with("died") else "departure"))

# ---------------------------------------------------------------- inbox ops (from overseers)
static func apply_op(state: Dictionary, op: Dictionary, tick: int) -> String:
	var rng := rng_for(state, tick, 999)
	var kind := str(op.get("op", ""))
	for key in ["text", "name", "note", "innate", "learned", "lifestyle", "currently", "occupation", "tone", "reason"]:
		if op.has(key) and not Filter.admit(str(op[key]), "inbox:" + kind):
			return "quarantined"
	match kind:
		"add_building":
			var b: Dictionary = op.get("building", {})
			for key in ["name", "note"]:
				if b.has(key) and not Filter.admit(str(b[key]), "inbox:building"):
					return "quarantined"
			b.id = int(state.next_id)
			state.next_id = int(state.next_id) + 1
			b.built_tick = tick
			if not b.has("x") or not Map.rect_free(state.map, int(b.x), int(b.y), int(b.get("w", 3)), int(b.get("h", 2))):
				var lot := Map.find_lot(state.map, int(b.get("w", 3)), int(b.get("h", 2)), rng)
				if lot.is_empty():
					Map.expand_south(state.map, int(R().get("growth", {}).get("expand_by", 8)), tick)
					lot = Map.find_lot(state.map, int(b.get("w", 3)), int(b.get("h", 2)), rng)
				if lot.is_empty():
					return "no room"
				b.x = lot[0]
				b.y = lot[1]
			Map.add_building(state.map, b)
			state.map_version = int(state.map_version) + 1
			add_event(state, tick, "%s opened on %s." % [b.get("name", "A new place"), nearest_street(state, b)], [], imp("event"))
			return "ok"
		"add_street":
			var s: Dictionary = op.get("street", {})
			if s.has("name") and not Filter.admit(str(s.name), "inbox:street"):
				return "quarantined"
			Schema_merge(s, Schema.STREET)
			s.built_tick = tick
			if int(s.x) + int(s.w) > int(state.map.w) or int(s.y) + int(s.h) > int(state.map.h):
				return "out of bounds"
			state.map.streets.append(s)
			Map.rebuild(state.map)
			state.map_version = int(state.map_version) + 1
			add_event(state, tick, "The town laid a new street: %s." % s.name, [], imp("event"))
			return "ok"
		"expand":
			Map.expand_south(state.map, int(op.get("by", 8)), tick)
			state.map_version = int(state.map_version) + 1
			return "ok"
		"add_citizen":
			var cd: Dictionary = op.get("citizen", {})
			for key in ["name", "innate", "learned", "lifestyle", "currently", "occupation"]:
				if cd.has(key) and not Filter.admit(str(cd[key]), "inbox:citizen"):
					return "quarantined"
			var c := make_citizen(state, rng, tick, cd)
			for r in op.get("relationships", []):
				var other := citizen(state, int(r[0]))
				if other.is_empty():
					continue
				if not Filter.check_relationship(str(r[1]), c.age, float(other.age)).ok:
					continue
				c.relationships[str(int(r[0]))] = {"kind": str(r[1]), "score": float(r[2]), "note": str(r[3]) if r.size() > 3 else ""}
				other.relationships[str(int(c.id))] = {"kind": str(r[1]), "score": float(r[2]) * 0.8, "note": ""}
			Memory.add(c, tick, "event", "I arrived in Vesper today. %s" % c.currently, imp("arrival"))
			state.stats.arrivals = int(state.stats.arrivals) + 1
			add_event(state, tick, "%s arrived in Vesper (%s)." % [c.name, c.occupation], [int(c.id)], imp("arrival"))
			return "ok"
		"event":
			var who: Array = []
			var target = op.get("who", "all")
			if typeof(target) == TYPE_ARRAY:
				for id in target:
					var c := citizen(state, int(id))
					if not c.is_empty() and c.alive:
						who.append(c)
			else:
				who = alive(state)
			for c in who:
				Memory.add(c, tick, "event", str(op.text), int(op.get("imp", 6)))
			add_event(state, tick, str(op.text), who.map(func(c): return int(c.id)), int(op.get("imp", 6)))
			return "ok"
		"depart":
			var c := citizen(state, int(op.get("id", -1)))
			if c.is_empty() or not c.alive:
				return "no such citizen"
			kill(state, c, tick, "left Vesper (%s)" % op.get("reason", "for reasons of their own"))
			state.stats.departures = int(state.stats.departures) + 1
			add_event(state, tick, "%s left Vesper. %s" % [c.name, op.get("reason", "")], [int(c.id)], imp("departure"))
			return "ok"
		"relationship":
			var a := citizen(state, int(op.get("a", -1)))
			var b := citizen(state, int(op.get("b", -1)))
			if a.is_empty() or b.is_empty():
				return "no such citizen"
			if not Filter.check_relationship(str(op.get("kind", "")), float(a.age), float(b.age)).ok:
				return "quarantined"
			a.relationships[str(int(b.id))] = {"kind": str(op.get("kind", "acquaintance")), "score": float(op.get("score", 0.3)), "note": str(op.get("note", ""))}
			return "ok"
		"set_journal":
			state.journal.name = str(op.get("name", state.journal.name))
			state.journal.tone = str(op.get("tone", state.journal.tone))
			return "ok"
	return "unknown op"

static func nearest_street(state: Dictionary, b: Dictionary) -> String:
	var best := ""
	var bd := 1e9
	for s in state.map.streets:
		var d := absf(float(b.y) - float(s.y)) + absf(float(b.x) - float(s.x))
		if d < bd:
			bd = d
			best = s.name
	return best

# ---------------------------------------------------------------- the tick
# brain: Callable(kind, state, citizen, ctx) -> bool ("a Tier 2 request was made")
static func step(state: Dictionary, tick: int, brain: Callable) -> Array:
	var events_before: int = state.events.size()
	state.tick = tick
	var sim := Clock.sim(tick)
	var rl := R()
	if sim.minute_of_day == 0 and int(state.last_daily_sample) != int(sim.day):
		_new_day(state, tick, sim, brain)
	if sim.minute == 0 and (tick % 6) == 0:
		_happenings(state, tick, sim)
		_hourly(state, tick, sim)
	var occ := {}
	var w := int(state.map.w)
	for c in state.citizens:
		if c.alive and c.action != "sleeping":
			var k := int(c.y) * w + int(c.x)
			if not occ.has(k):
				occ[k] = []
			occ[k].append(int(c.id))
	var by_id := index(state)
	var conv_rules: Dictionary = rl.get("conversation", {})
	var cons: Dictionary = rl.get("consciousness", {})
	for c in state.citizens:
		if not c.alive:
			continue
		var cid := int(c.id)
		var rng := rng_for(state, tick, cid)
		# visitors: no plans, no reflections; they leave when nobody has heard from them for a while
		if c.get("visitor", false):
			if tick >= int(c.get("expires_tick", 0)):
				kill(state, c, tick, "went back down the road")
				add_event(state, tick, "%s, the visitor, went back down the road." % c.name, [int(c.id)], 3)
				continue
		# daily plan (Tier 2) at plan_hour
		elif sim.hour == int(cons.get("plan_hour", 6)) and sim.minute == 0 and int(c.plan_day) != int(sim.day):
			if brain.call("plan", state, c, {"day": sim.day}):
				c.last_conscious_tick = tick
		# conversation in progress
		if not c.conv.is_empty():
			if tick >= int(c.conv.until):
				_end_conversation(state, tick, c, by_id)
			continue
		# which block of the day
		var blocks: Array = c.plan if (int(c.plan_day) == int(sim.day) and c.plan.size() > 0) else c.routine
		var bi := current_block(blocks, sim.minute_of_day)
		if bi != int(c.block) and bi >= 0:
			c.block = bi
			var blk: Dictionary = blocks[bi]
			var dest := resolve_place(state, c, str(blk.get("place", "home")))
			c.goal = Map.target_tile(state.map, dest, rng)
			c.path = Map.find_path(state.map, [int(c.x), int(c.y)], c.goal) if c.goal[0] >= 0 else []
			c.action = ("walking to %s" % dest.name) if c.path.size() > 0 else str(blk.get("action", "idle"))
			c.place = int(dest.id) if c.path.is_empty() else 0
			var cat := category(str(blk.get("action", "")))
			c.thought = pick(rl.get("thoughts", {}).get(cat if c.path.is_empty() else "walking", ["..."]), rng)
			if cat != "resting":
				Memory.add(c, tick, "routine", "%s at %s." % [cap(str(blk.get("action", "idle"))), dest.name], imp("routine"))
		# move one tile per tick
		if c.path.size() > 0:
			var nxt: Array = c.path.pop_front()
			var dx := int(nxt[0]) - int(c.x)
			var dy := int(nxt[1]) - int(c.y)
			if absi(dx) >= absi(dy) and dx != 0:
				c.facing = "east" if dx > 0 else "west"
			elif dy != 0:
				c.facing = "south" if dy > 0 else "north"
			c.x = int(nxt[0])
			c.y = int(nxt[1])
			if c.path.is_empty():
				var blk2: Dictionary = blocks[int(c.block)] if int(c.block) >= 0 and int(c.block) < blocks.size() else {}
				c.action = str(blk2.get("action", "idle"))
				c.place = int(_building_here(state, c).get("id", 0))
				if int(c.place) != 0 and int(c.place) != int(c.home):
					state.stats.visits = int(state.stats.get("visits", 0)) + 1   # metrics: building visits per day
				c.thought = pick(rl.get("thoughts", {}).get(category(c.action), ["..."]), rng)
		# perception: who is near? (every other tick, offset by id, to halve the cost during catch-up)
		if c.action != "sleeping" and (tick + cid) % 2 == 0 and tick - int(c.last_conv_tick) > int(conv_rules.get("cooldown_ticks", 720)):
			var radius := int(conv_rules.get("radius", 2))
			var partner := {}
			for dy in range(-radius, radius + 1):
				for dx in range(-radius, radius + 1):
					var k := (int(c.y) + dy) * w + int(c.x) + dx
					if not occ.has(k):
						continue
					for oid in occ[k]:
						if oid == cid:
							continue
						var o: Dictionary = by_id[oid]
						if not o.conv.is_empty() or tick - int(o.last_conv_tick) <= int(conv_rules.get("cooldown_ticks", 720)):
							continue
						partner = o
						break
					if not partner.is_empty():
						break
				if not partner.is_empty():
					break
			if not partner.is_empty():
				var rel: Dictionary = c.relationships.get(str(int(partner.id)), {})
				var chance := float(conv_rules.get("base_chance", 0.06)) + (float(conv_rules.get("friend_bonus", 0.1)) * float(rel.get("score", 0.0)) if not rel.is_empty() else 0.0)
				if rng.randf() < chance:
					_start_conversation(state, tick, c, partner, brain, rng)
					continue
		# reflection when enough has happened
		if int(c.imp_since_reflect) >= int(rl.get("reflection_threshold", 45)):
			if c.get("visitor", false):
				pass
			elif not brain.call("reflect", state, c, {}):
				Memory.tier1_reflect(c, tick, rl)
			else:
				c.last_conscious_tick = tick
				c.imp_since_reflect = 0
	return state.events.slice(events_before)

static func _building_here(state: Dictionary, c: Dictionary) -> Dictionary:
	for b in state.map.buildings:
		if Map.inside(b, int(c.x), int(c.y)) or (int(b.door[0]) == int(c.x) and int(b.door[1]) == int(c.y)):
			return b
	return {}

static func _start_conversation(state: Dictionary, tick: int, a: Dictionary, b: Dictionary, brain: Callable, rng: RandomNumberGenerator) -> void:
	var conv_rules: Dictionary = R().get("conversation", {})
	var dur := int(conv_rules.get("duration_ticks", 10))
	# the conversation exists before the brain is asked, so a Tier 2 reply (sync or async) can fill its lines
	for pair in [[a, b], [b, a]]:
		var me: Dictionary = pair[0]
		var other: Dictionary = pair[1]
		me.conv = {"with": int(other.id), "lines": ["%s: ..." % a.name], "until": tick + dur, "started": tick, "tier2": false}
		me.path = []
		me.block = -1
		me.action = "talking with %s" % other.name
		me.last_conv_tick = tick
	var tier2: bool = brain.call("chat", state, a, {"with": int(b.id)})
	if tier2:
		a.last_conscious_tick = tick
		a.conv.tier2 = true
		b.conv.tier2 = true
	else:
		var tpl: Array = pick(R().get("small_talk", [["Morning.", "Morning."]]), rng)
		var lines: Array = []
		for i in tpl.size():
			lines.append("%s: %s" % [(a.name if i % 2 == 0 else b.name), tpl[i]])
		a.conv.lines = lines
		b.conv.lines = lines
	state.stats.conversations = int(state.stats.conversations) + 1
	add_event(state, tick, "%s and %s stopped to talk near %s." % [a.name, b.name, place_name(state, a)], [int(a.id), int(b.id)], imp("meet"))

static func _end_conversation(state: Dictionary, tick: int, c: Dictionary, by_id: Dictionary) -> void:
	var conv: Dictionary = c.conv
	var other: Dictionary = by_id.get(int(conv.with), {})
	var lines: Array = conv.get("lines", [])
	var gist := ""
	if lines.size() > 0:
		gist = str(lines[0]).get_slice(": ", 1)
		if lines.size() > 1:
			gist += " ... " + str(lines[lines.size() - 1]).get_slice(": ", 1)
	var oname: String = other.get("name", "someone")
	var kind := "chat" if conv.get("tier2", false) else "meet"
	Memory.add(c, tick, "chat", "Talked with %s: %s" % [oname, gist], imp(kind))
	if not other.is_empty():
		relate(c, int(other.id), "acquaintance", 0.02)
	c.conv = {}
	c.block = -1
	c.action = "idle"

static func _new_day(state: Dictionary, tick: int, sim: Dictionary, brain: Callable) -> void:
	state.last_daily_sample = int(sim.day)
	var rl := R()
	var pop: Dictionary = rl.get("population", {})
	var rng := rng_for(state, tick, 7777)
	var living := alive(state)
	for c in living:
		c.age = float(c.age) + 1.0 / 365.0
		c.mood = pick(rl.get("moods", ["calm"]), rng)
		Memory.prune(c, rl)
		# deaths
		var over := float(c.age) - float(pop.get("death_age", 78))
		if over > 0.0 and rng.randf() < over * float(pop.get("death_daily_chance_per_year_over", 0.004)):
			kill(state, c, tick, "died at home, aged %d" % int(c.age))
			state.stats.deaths = int(state.stats.deaths) + 1
			add_event(state, tick, "%s died, aged %d. The town noticed." % [c.name, int(c.age)], [int(c.id)], imp("death"))
			continue
		# departures: nobody close, and the road is right there
		var closest := 0.0
		for k in c.relationships:
			closest = maxf(closest, float(c.relationships[k].score))
		if closest < 0.3 and float(c.age) >= float(pop.get("adult_age", 18)) and rng.randf() < float(pop.get("departure_daily_chance", 0.0015)):
			kill(state, c, tick, "left Vesper along the coast road")
			state.stats.departures = int(state.stats.departures) + 1
			add_event(state, tick, "%s left Vesper along the coast road, without much of a goodbye." % c.name, [int(c.id)], imp("departure"))
			continue
		# children grow up
		if float(c.age) >= 6.0 and c.routine.size() == 1:
			c.routine = rl.routines.default.duplicate(true)
			c.work = int(Map.first_of_kind(state.map, "hall").get("id", c.home))
		if float(c.age) >= float(pop.get("adult_age", 18)) and c.occupation == "child":
			c.occupation = pick(rl.get("occupations", ["fisher"]), rng)
			var opts_w: Array = state.map.buildings.filter(func(b): return b.kind not in ["house", "square", "pier"])
			if opts_w.size() > 0:
				c.work = int(pick(opts_w, rng).id)
			Memory.add(c, tick, "event", "I am grown now, and Vesper calls me a %s." % c.occupation, imp("event"))
	# births
	for c in alive(state):
		for key in c.relationships:
			var r: Dictionary = c.relationships[key]
			if r.kind != "partner" or int(key) < int(c.id):
				continue
			var o := citizen(state, int(key))
			if o.is_empty() or not o.alive:
				continue
			if not Filter.check_relationship("partner", float(c.age), float(o.age)).ok:
				continue
			if rng.randf() < float(pop.get("birth_daily_chance", 0.02)):
				var baby := make_citizen(state, rng, tick, {"age": 0, "home": int(c.home), "parents": [int(c.id), int(o.id)], "occupation": "child",
					"innate": "small, loud, undecided", "learned": "nothing yet", "lifestyle": "sleeps, eats, is carried", "currently": "brand new"})
				baby.routine = [{"at": "00:00", "place": "home", "action": "being small"}]
				for parent in [c, o]:
					Memory.add(parent, tick, "event", "%s was born. Everything is different now." % baby.name, imp("birth"))
					parent.relationships[str(int(baby.id))] = {"kind": "child", "score": 1.0, "note": "ours"}
					baby.relationships[str(int(parent.id))] = {"kind": "parent", "score": 1.0, "note": ""}
				state.stats.births = int(state.stats.births) + 1
				add_event(state, tick, "%s was born to %s and %s." % [baby.name, c.name, o.name], [int(c.id), int(o.id), int(baby.id)], imp("birth"))
	# arrivals when nobody has come for a while (the Weaver usually does this with more care)
	var since_last := 999999
	for c in state.citizens:
		since_last = mini(since_last, tick - int(c.arrived_tick))
	if since_last > int(pop.get("arrival_quiet_days", 10)) * Clock.TICKS_PER_DAY and rng.randf() < float(pop.get("arrival_daily_chance", 0.08)):
		var nc := make_citizen(state, rng, tick)
		Memory.add(nc, tick, "event", "I walked into Vesper along the coast road with one bag.", imp("arrival"))
		state.stats.arrivals = int(state.stats.arrivals) + 1
		add_event(state, tick, "%s walked into town along the coast road, looking for work as a %s." % [nc.name, nc.occupation], [int(nc.id)], imp("arrival"))
	# growth: beds before anything else
	while housing_shortfall(state) > 0:
		if build_house(state, rng, tick).is_empty():
			break
	var needs: Array = []
	if housing_shortfall(state) > 0:
		needs.append("housing")
	var living_n := alive(state).size()
	var kinds := {}
	for b in state.map.buildings:
		kinds[b.kind] = int(kinds.get(b.kind, 0)) + 1
	if living_n > 14 * int(kinds.get("cafe", 1)):
		needs.append("another place to eat and gather")
	if living_n > 20 and not kinds.has("school"):
		needs.append("a school or a place for children")
	if living_n > 24 and not kinds.has("workshop"):
		needs.append("workplaces: a workshop, a boatyard, something to do")
	state.stats.needs = needs
	state.history.append({"day": int(sim.day), "pop": living_n, "buildings": state.map.buildings.size(), "w": int(state.map.w), "h": int(state.map.h), "streets": state.map.streets.size(),
		"conversations": int(state.stats.conversations), "visits": int(state.stats.get("visits", 0))})
	while state.history.size() > 2000:
		state.history.remove_at(0)

static func _happenings(state: Dictionary, tick: int, sim: Dictionary) -> void:
	var rng := rng_for(state, tick, 4242)
	for hap in R().get("happenings", []):
		if rng.randf() >= float(hap.get("chance", 0.0)):
			continue
		var witnesses: Array = []
		for c in alive(state):
			if c.action != "sleeping" and rng.randf() < 0.5:
				witnesses.append(c)
		if witnesses.is_empty():
			continue
		var text: String = str(hap.text)
		for c in witnesses:
			Memory.add(c, tick, "obs", "Today %s." % text, int(hap.get("imp", 4)))
		add_event(state, tick, text[0].to_upper() + text.substr(1) + ".", witnesses.map(func(c): return int(c.id)), int(hap.get("imp", 4)))
		break  # at most one happening per hour

# ---------------------------------------------------------------- seasons, weather, daylight (Phase 2 hooks; the content is the overseers')
static func season_for(day: int, rl: Dictionary) -> String:
	var sr: Dictionary = rl.get("season", {})
	if str(sr.get("override", "")) != "":
		return str(sr.override)
	var by_month: Array = sr.get("by_month", [])
	if by_month.is_empty():
		return "spring"
	var month := int((day % (Clock.DAYS_PER_MONTH * 12)) / Clock.DAYS_PER_MONTH)
	return str(by_month[month % by_month.size()])

## piecewise-linear light 0..1 over the sim day from rules.daylight [[hour, light], ...]
static func daylight(minute_of_day: int, rl: Dictionary) -> float:
	var curve: Array = rl.get("daylight", [[0, 1.0], [24, 1.0]])
	var h := float(minute_of_day) / 60.0
	for i in range(curve.size() - 1):
		var a: Array = curve[i]
		var b: Array = curve[i + 1]
		if h >= float(a[0]) and h <= float(b[0]):
			return lerpf(float(a[1]), float(b[1]), (h - float(a[0])) / maxf(0.001, float(b[0]) - float(a[0])))
	return float(curve[curve.size() - 1][1])

static func activity(c: Dictionary) -> String:
	return "walking" if c.path.size() > 0 else category(str(c.action))

## what the viewer needs to light and colour the town; pure over (state, tick)
static func world_view(state: Dictionary, tick: int) -> Dictionary:
	var rl := R()
	var sim := Clock.sim(tick)
	var season := season_for(int(sim.day), rl)
	var weather := str(state.get("weather", "clear"))
	var dl := daylight(int(sim.minute_of_day), rl)
	var wl: Dictionary = rl.get("weather", {}).get("light", {})
	return {"season": season, "weather": weather, "daylight": snappedf(dl, 0.01), "light": snappedf(dl * float(wl.get(weather, 1.0)), 0.01),
		"tint": str(rl.get("season_tint", {}).get(season, "#ffffff"))}

## once per sim hour: the season turning and the weather rolling, both from the deterministic RNG so replay agrees
static func _hourly(state: Dictionary, tick: int, sim: Dictionary) -> void:
	var rl := R()
	var season := season_for(int(sim.day), rl)
	if season != str(state.get("season", "")):
		var first := str(state.get("season", "")) == ""
		state.season = season
		if not first and tick > 0:
			var ids: Array = []
			for c in alive(state):
				Memory.add(c, tick, "obs", "%s has come to Vesper." % season.capitalize(), 5)
				ids.append(int(c.id))
			add_event(state, tick, "%s came to Vesper." % season.capitalize(), ids, 5)
	var w: Dictionary = rl.get("weather", {})
	var every := int(w.get("change_every_hours", 6))
	if every <= 0 or int(sim.hour) % every != 0:
		return
	var kinds: Dictionary = w.get("by_season", {}).get(season, w.get("kinds", {"clear": 1.0}))
	var total := 0.0
	for k in kinds:
		total += float(kinds[k])
	var rng := rng_for(state, tick, 7331)
	var roll := rng.randf() * total
	var pick := str(kinds.keys()[0])
	for k in kinds:
		roll -= float(kinds[k])
		if roll <= 0.0:
			pick = str(k)
			break
	var before := str(state.get("weather", "clear"))
	state.weather = pick
	state.weather_since = tick
	var notable := {"rain": "rain came in off the sea", "storm": "a storm broke over the harbour", "fog": "fog swallowed the pier", "snow": "snow began to fall"}
	if pick != before and notable.has(pick):
		var text: String = notable[pick]
		var ids: Array = []
		for c in alive(state):
			if c.action != "sleeping":
				Memory.add(c, tick, "obs", "Today %s." % text, 3)
				ids.append(int(c.id))
		if not ids.is_empty():
			add_event(state, tick, text[0].to_upper() + text.substr(1) + ".", ids, 3)

# ---------------------------------------------------------------- visitors (Phase 2): temporary citizens who live in the server sim
static func add_visitor(state: Dictionary, tick: int, name: String) -> Dictionary:
	var rng := rng_for(state, tick, 4711 + state.citizens.size())
	var c := make_citizen(state, rng, tick, {"name": name, "age": 30, "pronouns": "they/them", "occupation": "visitor", "innate": "curious, polite",
		"learned": "came in along the coast road today", "lifestyle": "passing through", "currently": "seeing Vesper for the first time"})
	for b in state.map.buildings:
		b.residents.erase(int(c.id))
	c.home = 0
	c.work = 0
	c.place = 0   # make_citizen parked them at a home; a visitor stands outdoors
	c.routine = []
	c.plan = []
	c.visitor = true
	c.expires_tick = tick + int(R().get("visitor", {}).get("ttl_ticks", 180))
	c.action = "looking around"
	c.color = "#d8c8ff"
	var spot := resolve_place(state, c, "square")
	var t: Array = Map.target_tile(state.map, spot, rng) if not spot.is_empty() else [int(state.map.w) / 2, int(state.map.h) / 2]
	if t.size() == 2 and int(t[0]) >= 0:
		c.x = int(t[0])
		c.y = int(t[1])
	var ids: Array = []
	for o in alive(state):
		if int(o.id) != int(c.id) and o.action != "sleeping" and absi(int(o.x) - int(c.x)) + absi(int(o.y) - int(c.y)) <= 8:
			Memory.add(o, tick, "obs", "A visitor called %s came into town." % c.name, 3)
			ids.append(int(o.id))
	add_event(state, tick, "A visitor, %s, walked into Vesper." % c.name, ids, 4)
	return c

static func nearest_local(state: Dictionary, v: Dictionary, radius: int) -> Dictionary:
	var best := {}
	var bd := radius + 1
	for o in alive(state):
		if o.get("visitor", false) or int(o.id) == int(v.id) or o.action == "sleeping":
			continue
		var dd := absi(int(o.x) - int(v.x)) + absi(int(o.y) - int(v.y))
		if dd < bd:
			bd = dd
			best = o
	return best

## the visitor speaks; the nearest citizen answers through Tier 2 (kind "visit") or, when the brain declines, with a Tier 1 line
static func visitor_say(state: Dictionary, tick: int, v: Dictionary, text: String, brain: Callable) -> Dictionary:
	var vr: Dictionary = R().get("visitor", {})
	v.expires_tick = tick + int(vr.get("ttl_ticks", 180))
	var c := nearest_local(state, v, int(vr.get("radius", 3)))
	if c.is_empty():
		return {"ok": false, "why": "nobody close enough to hear you"}
	var said := text.left(200)
	var dur := int(R().get("conversation", {}).get("duration_ticks", 10))
	for pair in [[v, c], [c, v]]:
		pair[0].conv = {"with": int(pair[1].id), "lines": ["%s: %s" % [v.name, said]], "until": tick + dur, "started": tick, "tier2": false, "visitor": true}
	c.last_conv_tick = tick
	var tier2: bool = brain.call("visit", state, c, {"with": int(v.id), "text": said})
	if not tier2:
		var reply := str(pick(vr.get("replies", ["Welcome to Vesper."]), rng_for(state, tick, int(c.id))))
		c.conv.lines.append("%s: %s" % [c.name, reply])
		v.conv.lines = c.conv.lines
		Memory.add(c, tick, "chat", "A visitor, %s, said \"%s\". I said \"%s\"." % [v.name, said, reply], imp("visit"))
		relate(c, int(v.id), "acquaintance", 0.05, "a visitor who spoke to me")
	return {"ok": true, "citizen": c.name, "tier2": tier2}

static func visitor_gift(state: Dictionary, tick: int, v: Dictionary, item: String) -> Dictionary:
	var vr: Dictionary = R().get("visitor", {})
	v.expires_tick = tick + int(vr.get("ttl_ticks", 180))
	var c := nearest_local(state, v, int(vr.get("radius", 3)))
	if c.is_empty():
		return {"ok": false, "why": "nobody close enough to give it to"}
	var it := item.left(40)
	Memory.add(c, tick, "event", "A visitor, %s, gave me %s." % [v.name, it], imp("gift"))
	relate(c, int(v.id), "acquaintance", 0.1, "gave me %s" % it)
	c.thought = "%s. From a stranger." % it.capitalize()
	add_event(state, tick, "%s gave %s %s." % [v.name, c.name, it], [int(c.id), int(v.id)], imp("gift"))
	return {"ok": true, "citizen": c.name}
