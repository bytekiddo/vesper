# The visitor path without a browser: `godot --headless --path . -s world/visitor_check.gd`
# A visitor joins a fresh world, walks, speaks to the nearest citizen through the (stubbed) Tier 2 "visit" kind,
# gives a gift, and the citizen's memories carry both; then the visitor expires. Prints one JSON line; exit 0 = ok.
extends SceneTree

const Clock = preload("res://kernel/clock.gd")
const Sim = preload("res://world/sim.gd")
const Cognition = preload("res://world/cognition.gd")
const Filter = preload("res://kernel/content_filter.gd")

var pending: Array = []

func brain(kind: String, state: Dictionary, c: Dictionary, ctx: Dictionary) -> bool:
	# the server queues Tier 2 results and applies them at the next tick; do the same
	pending.append([kind, c, ctx, Cognition.stub(kind, state, c, ctx, int(state.tick))])
	return true

func _initialize() -> void:
	var state := Sim.new_from_seed()
	var tick := 12 * 360   # noon
	for i in tick:
		Sim.step(state, i + 1, func(_k, _s, _c, _x): return false)
	var v := Sim.add_visitor(state, tick, "Mara Quill")
	var local := Sim.nearest_local(state, v, 99)
	v.x = int(local.x)
	v.y = int(local.y)
	var say := Sim.visitor_say(state, tick, v, "Hello — is this the way to the pier?", Callable(self, "brain"))
	for p in pending:
		Cognition.apply(p[0], state, p[1], p[2], p[3], tick + 1)
	pending.clear()
	var gift := Sim.visitor_gift(state, tick + 1, v, "a jar of sea glass")
	var texts: Array = local.memories.map(func(m): return str(m.text))
	var heard := texts.filter(func(t): return t.findn("Mara Quill") >= 0 and t.findn("pier") >= 0).size() > 0
	var got := texts.filter(func(t): return t.findn("gave me a jar of sea glass") >= 0).size() > 0
	var blocked: bool = not Filter.check("A citizen named Elon Musk moved in.").ok
	for i in range(int(Sim.R().get("visitor", {}).get("ttl_ticks", 180)) + 2):
		Sim.step(state, tick + 2 + i, func(_k, _s, _c, _x): return false)
	var gone: bool = not Sim.citizen(state, int(v.id)).alive
	var ok := bool(say.get("ok", false)) and bool(say.get("tier2", false)) and bool(gift.get("ok", false)) and heard and got and blocked and gone
	print(JSON.stringify({"ok": ok, "spoke_to": say.get("citizen", ""), "tier2": say.get("tier2", false), "heard": heard, "gift_remembered": got,
		"filter_blocks_real_people": blocked, "visitor_expired": gone, "memories": texts.filter(func(t): return t.findn("visitor") >= 0 or t.findn("Mara") >= 0)}))
	quit(0 if ok else 1)
