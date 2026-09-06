# Memory stream + retrieval + reflection (Park et al. 2023), on citizen Dictionaries.
# Score = w_recency * decay^hours_since_access + w_importance * imp/10 + w_relevance * jaccard(query, text)
extends RefCounted

const Clock = preload("res://kernel/clock.gd")

const STOP := {"the": 1, "a": 1, "an": 1, "and": 1, "or": 1, "of": 1, "to": 1, "in": 1, "on": 1, "at": 1, "is": 1, "it": 1, "i": 1, "was": 1, "for": 1, "with": 1, "that": 1, "this": 1, "my": 1, "me": 1, "he": 1, "she": 1, "they": 1, "we": 1, "you": 1, "be": 1, "as": 1, "by": 1, "not": 1, "but": 1, "are": 1, "from": 1, "have": 1, "has": 1, "had": 1, "there": 1, "than": 1, "then": 1, "so": 1, "its": 1, "into": 1, "about": 1}

static func add(c: Dictionary, tick: int, kind: String, text: String, imp: int, cites: Array = []) -> Dictionary:
	var m := {"t": tick, "kind": kind, "text": text, "imp": clampi(imp, 1, 10), "last": tick, "cites": cites}
	c.memories.append(m)
	c.imp_since_reflect = int(c.imp_since_reflect) + m.imp
	return m

static func tokens(text: String) -> Dictionary:
	var out := {}
	var re := RegEx.new()
	re.compile("[a-zA-Z']+")
	for r in re.search_all(text.to_lower()):
		var w := r.get_string().trim_prefix("'").trim_suffix("'")
		if w.length() > 2 and not STOP.has(w):
			out[w] = true
	return out

static func jaccard(a: Dictionary, b: Dictionary) -> float:
	if a.is_empty() or b.is_empty():
		return 0.0
	var inter := 0
	for k in a:
		if b.has(k):
			inter += 1
	return float(inter) / float(a.size() + b.size() - inter)

static func retrieve(c: Dictionary, tick: int, query: String, rules: Dictionary) -> Array:
	var r: Dictionary = rules.get("retrieval", {})
	var decay := float(r.get("recency_decay_per_sim_hour", 0.97))
	var wr := float(r.get("w_recency", 1.0))
	var wi := float(r.get("w_importance", 1.0))
	var wv := float(r.get("w_relevance", 1.2))
	var k := int(r.get("top_k", 10))
	var q := tokens(query)
	var scored: Array = []
	for m in c.memories:
		var hours := float(tick - int(m.last)) * Clock.SIM_SECONDS_PER_TICK / 3600.0
		var s := wr * pow(decay, hours) + wi * float(m.imp) / 10.0 + wv * jaccard(q, tokens(m.text))
		scored.append([s, m])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var out: Array = []
	for i in mini(k, scored.size()):
		scored[i][1].last = tick
		out.append(scored[i][1])
	out.sort_custom(func(a, b): return int(a.t) < int(b.t))
	return out

static func recent(c: Dictionary, n: int) -> Array:
	var ms: Array = c.memories
	return ms.slice(maxi(0, ms.size() - n))

static func line(m: Dictionary) -> String:
	var s := Clock.sim(int(m.t))
	return "[%s %s] (%s) %s" % [s.date, s.hhmm, m.kind, m.text]

static func lines(ms: Array) -> String:
	var out := PackedStringArray()
	for m in ms:
		out.append(line(m))
	return "\n".join(out)

# Free reflection: the three most important recent memories become one insight. Tier 2 replaces this when funded.
static func tier1_reflect(c: Dictionary, tick: int, rules: Dictionary) -> void:
	var rec := recent(c, 40)
	rec.sort_custom(func(a, b): return int(a.imp) > int(b.imp))
	var top: Array = rec.slice(0, mini(3, rec.size()))
	if top.is_empty():
		return
	var bits := PackedStringArray()
	for m in top:
		bits.append(m.text.trim_suffix("."))
	var text := "I keep coming back to this: %s." % "; ".join(bits)
	var cites: Array = []
	for m in top:
		cites.append(int(m.t))
	add(c, tick, "reflect", text, int(rules.get("importance", {}).get("reflect", 7)), cites)
	c.last_reflect_tick = tick
	c.imp_since_reflect = 0

# Keeps the stream under `memory_cap`: drops the oldest low-importance memories first.
static func prune(c: Dictionary, rules: Dictionary) -> void:
	var cap := int(rules.get("memory_cap", 240))
	var keep_over := int(rules.get("memory_prune_keep_importance_over", 6))
	if c.memories.size() <= cap:
		return
	var level := 1
	while c.memories.size() > cap and level <= keep_over:
		var i := 0
		while i < c.memories.size() and c.memories.size() > cap:
			if int(c.memories[i].imp) <= level:
				c.memories.remove_at(i)
			else:
				i += 1
		level += 1
	while c.memories.size() > cap:
		c.memories.remove_at(0)
