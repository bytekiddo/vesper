# Tier 2 "consciousness": prompts for plan / reflect / chat, deterministic stubs for the smoke test,
# and the only path by which model output enters world state (through the kernel content filter).
extends RefCounted

const Clock = preload("res://kernel/clock.gd")
const Filter = preload("res://kernel/content_filter.gd")
const Map = preload("res://world/map.gd")
const Memory = preload("res://world/memory.gd")
const Sim = preload("res://world/sim.gd")

static func can_think(c: Dictionary, tick: int) -> bool:
	var gap := int(Sim.R().get("consciousness", {}).get("min_ticks_between", 1440))
	return tick - int(c.last_conscious_tick) >= gap

static func persona(state: Dictionary, c: Dictionary) -> String:
	var home: String = str(Map.building(state.map, int(c.home)).get("name", "nowhere"))
	var work: String = str(Map.building(state.map, int(c.work)).get("name", "nowhere"))
	return "Name: %s (%s), age %d, %s.\nInnate: %s\nLearned: %s\nLifestyle: %s\nCurrently: %s\nLives at %s; works at %s." % [
		c.name, c.pronouns, int(c.age), c.occupation, c.innate, c.learned, c.lifestyle, c.currently, home, work]

static func relationships(state: Dictionary, c: Dictionary) -> String:
	var out := PackedStringArray()
	for key in c.relationships:
		var o := Sim.citizen(state, int(key))
		if o.is_empty():
			continue
		var r: Dictionary = c.relationships[key]
		out.append("- %s: %s (%.1f) %s" % [o.name, r.kind, float(r.score), r.get("note", "")])
	return "\n".join(out) if out.size() > 0 else "- nobody in particular"

static func places(state: Dictionary) -> String:
	var out := PackedStringArray()
	for b in state.map.buildings:
		out.append("%s (%s)" % [b.name, b.kind])
	return ", ".join(out)

static func prompt(kind: String, state: Dictionary, c: Dictionary, ctx: Dictionary, tick: int) -> Dictionary:
	var sim := Clock.sim(tick)
	var sys := "You are %s, a citizen of Vesper, a small fictional coastal town with a lighthouse nobody remembers building. Stay in character. Be concrete and brief. Never mention real people, brands, or the modern world. Reply with a single JSON object and nothing else." % c.name
	var head := "%s\n\nRelationships:\n%s\n\nIt is %s, %s, %s.\n" % [persona(state, c), relationships(state, c), sim.weekday, sim.date, sim.hhmm]
	match kind:
		"plan":
			var mem := Memory.lines(Memory.retrieve(c, tick, c.currently + " plan for today", Sim.R()))
			return {"system": sys, "max_tokens": 600, "user": head + "\nRelevant memories:\n%s\n\nPlaces you can go: %s. You may also say \"home\" or \"work\".\n\nPlan your day as 5 to 8 blocks in order. Keep your habits unless a memory gives you a reason not to.\nJSON: {\"plan\":[{\"at\":\"HH:MM\",\"place\":\"<place name, home or work>\",\"action\":\"<what you do, under 10 words>\"}],\"thought\":\"<one line, first person>\",\"currently\":\"<your current concern in one line>\"}" % [mem, places(state)]}
		"reflect":
			var rec := Memory.recent(c, 25)
			return {"system": sys, "max_tokens": 500, "user": head + "\nRecent memories (index: text):\n%s\n\nWhat are 2 or 3 high-level insights you can draw from these? Each must cite the indices it rests on.\nJSON: {\"insights\":[{\"text\":\"<one sentence, first person>\",\"cites\":[<index>,...]}],\"mood\":\"<one word>\"}" % _indexed(rec)}
		"chat":
			var other := Sim.citizen(state, int(ctx.get("with", -1)))
			var mem := Memory.lines(Memory.retrieve(c, tick, other.get("name", "") + " " + c.currently, Sim.R()))
			var omem := Memory.lines(Memory.retrieve(other, tick, c.name + " " + other.get("currently", ""), Sim.R())) if not other.is_empty() else ""
			return {"system": sys, "max_tokens": 700, "user": head + "\nYour relevant memories:\n%s\n\nYou run into %s near %s.\nAbout them:\n%s\nTheir relevant memories (you do not know these, but they shape what they say):\n%s\n\nWrite the exchange: 2 to 6 short lines, alternating, both in character. Then say what you take away.\nJSON: {\"lines\":[{\"who\":\"<name>\",\"text\":\"<line>\"}],\"my_takeaway\":\"<one line, first person>\",\"relationship\":{\"kind\":\"<friend|neighbour|acquaintance|rival|colleague|old friend|partner>\",\"score_delta\":<-0.1 to 0.1>,\"note\":\"<one line about them>\"}}" % [mem, other.get("name", "someone"), Sim.place_name(state, c), persona(state, other) if not other.is_empty() else "", omem]}
	return {"system": sys, "user": head, "max_tokens": 200}

static func _indexed(ms: Array) -> String:
	var out := PackedStringArray()
	for i in ms.size():
		out.append("%d: %s" % [i, Memory.line(ms[i])])
	return "\n".join(out)

# Deterministic canned replies so the smoke test exercises every apply() path without a model.
static func stub(kind: String, state: Dictionary, c: Dictionary, ctx: Dictionary, tick: int) -> String:
	match kind:
		"plan":
			var blocks: Array = []
			for b in c.routine:
				blocks.append({"at": b.at, "place": b.place, "action": b.action})
			return JSON.stringify({"plan": blocks, "thought": "Same day as yesterday, and glad of it.", "currently": c.currently})
		"reflect":
			return JSON.stringify({"insights": [{"text": "The lighthouse matters more to me than I admit.", "cites": [0, 1]}, {"text": "The town is smaller than its stories.", "cites": [2]}], "mood": "wistful"})
		"chat":
			var other := Sim.citizen(state, int(ctx.get("with", -1)))
			var on: String = other.get("name", "someone")
			return JSON.stringify({"lines": [{"who": c.name, "text": "Did you see the lamp last night?"}, {"who": on, "text": "I try not to look at it."}, {"who": c.name, "text": "That's fair."}],
				"my_takeaway": "%s does not want to talk about the lamp either." % on, "relationship": {"kind": "acquaintance", "score_delta": 0.05, "note": "avoids the lamp"}})
	return "{}"

# Applies a model reply. Returns true if anything entered world state. Filtered by the kernel first.
static func apply(kind: String, state: Dictionary, c: Dictionary, ctx: Dictionary, text: String, tick: int) -> bool:
	if not Filter.admit(text, "citizen:" + kind):
		return false
	var data = _parse(text)
	if typeof(data) != TYPE_DICTIONARY:
		return false
	var moods: Array = Sim.R().get("moods", [])
	match kind:
		"plan":
			var plan: Array = []
			for b in data.get("plan", []):
				if typeof(b) != TYPE_DICTIONARY:
					continue
				var at := str(b.get("at", "")).strip_edges()
				if not at.is_valid_int() and at.find(":") < 0:
					continue
				plan.append({"at": at.left(5), "place": str(b.get("place", "home")).left(60), "action": str(b.get("action", "idle")).left(80)})
			if plan.size() < 3:
				return false
			plan.sort_custom(func(a, b): return Clock.hhmm_to_minute(a.at) < Clock.hhmm_to_minute(b.at))
			c.plan = plan
			c.plan_day = int(ctx.get("day", Clock.sim(tick).day))
			c.block = -1
			if str(data.get("thought", "")) != "":
				c.thought = str(data.thought).left(160)
			if str(data.get("currently", "")) != "":
				c.currently = str(data.currently).left(200)
			var bits := PackedStringArray()
			for b in plan:
				bits.append("%s %s" % [b.at, b.action])
			Memory.add(c, tick, "plan", "My plan today: %s." % "; ".join(bits), Sim.imp("plan"))
			state.stats.tier2_applied = int(state.stats.tier2_applied) + 1
			return true
		"reflect":
			var rec := Memory.recent(c, 25)
			var n := 0
			for ins in data.get("insights", []):
				if typeof(ins) != TYPE_DICTIONARY or str(ins.get("text", "")) == "":
					continue
				var cites: Array = []
				for i in ins.get("cites", []):
					if typeof(i) == TYPE_FLOAT or typeof(i) == TYPE_INT:
						var ii := int(i)
						if ii >= 0 and ii < rec.size():
							cites.append(int(rec[ii].t))
				Memory.add(c, tick, "reflect", str(ins.text).left(240), Sim.imp("reflect"), cites)
				n += 1
			if n == 0:
				return false
			c.last_reflect_tick = tick
			c.imp_since_reflect = 0
			if data.get("mood", "") in moods:
				c.mood = data.mood
			c.thought = str(data.insights[0].text).left(160)
			state.stats.tier2_applied = int(state.stats.tier2_applied) + 1
			return true
		"chat":
			var other := Sim.citizen(state, int(ctx.get("with", -1)))
			var lines: Array = []
			for l in data.get("lines", []):
				if typeof(l) == TYPE_DICTIONARY and str(l.get("text", "")) != "":
					lines.append("%s: %s" % [str(l.get("who", c.name)).left(40), str(l.text).left(200)])
			if lines.is_empty():
				return false
			lines = lines.slice(0, int(Sim.R().get("conversation", {}).get("max_lines", 6)))
			var live: bool = not c.conv.is_empty() and int(c.conv.get("with", -1)) == int(ctx.get("with", -1))
			if live:
				c.conv.lines = lines
				c.conv.tier2 = true
				if not other.is_empty() and not other.conv.is_empty():
					other.conv.lines = lines
					other.conv.tier2 = true
			else:
				Memory.add(c, tick, "chat", "Talked with %s: %s" % [other.get("name", "someone"), str(lines[0]).get_slice(": ", 1)], Sim.imp("chat"))
			if str(data.get("my_takeaway", "")) != "":
				Memory.add(c, tick, "chat", str(data.my_takeaway).left(240), Sim.imp("chat"))
				c.thought = str(data.my_takeaway).left(160)
			var rel = data.get("relationship", {})
			if typeof(rel) == TYPE_DICTIONARY and not other.is_empty():
				var rkind := str(rel.get("kind", "")).left(20)
				if Filter.check_relationship(rkind, float(c.age), float(other.age)).ok:
					Sim.relate(c, int(other.id), rkind, clampf(float(rel.get("score_delta", 0.0)), -0.1, 0.1), str(rel.get("note", "")).left(120))
					if rkind != "" and rkind not in ["", "acquaintance"]:
						c.relationships[str(int(other.id))].kind = rkind
			state.stats.tier2_applied = int(state.stats.tier2_applied) + 1
			return true
	return false

static func _parse(text: String):
	var t := text.strip_edges()
	if t.begins_with("```"):
		t = t.substr(t.find("\n") + 1)
		if t.ends_with("```"):
			t = t.left(t.length() - 3)
	var v = JSON.parse_string(t)
	if v != null:
		return v
	var a := t.find("{")
	var b := t.rfind("}")
	if a >= 0 and b > a:
		return JSON.parse_string(t.substr(a, b - a + 1))
	return null
