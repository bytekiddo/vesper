# Sim-derived metrics merged into state/metrics.json every housekeeping pass (server.gd).
# The Director reads them, the hypothesis verifier checks "<metric> will rise|fall to <value>" against them.
# Pure: reads the state, never mutates it. Rates come from the daily samples in state.history.
extends RefCounted

const Clock = preload("res://kernel/clock.gd")
const ECHO_DAYS := 7   # ponytail: "recent feature" = a building built or a citizen arrived within 7 sim days; make it a rule if anyone needs to tune it

static func compute(state: Dictionary, rules: Dictionary) -> Dictionary:
	var living: Array = state.citizens.filter(func(c): return c.get("alive", true))
	var n := living.size()
	var out := {"population": n, "conversations_per_day": 0, "building_visits_per_day": 0}
	var h: Array = state.get("history", [])
	if h.size() >= 2:
		var a: Dictionary = h[h.size() - 2]
		var b: Dictionary = h[h.size() - 1]
		out.conversations_per_day = int(b.get("conversations", 0)) - int(a.get("conversations", 0))
		out.building_visits_per_day = int(b.get("visits", 0)) - int(a.get("visits", 0))
	var valence: Dictionary = rules.get("mood_valence", {})
	var mood_sum := 0.0
	var actions := {}
	var jobs := {}
	var awake := 0
	for c in living:
		mood_sum += float(valence.get(str(c.get("mood", "")), 0.0))
		var job := str(c.get("occupation", "?"))
		jobs[job] = int(jobs.get(job, 0)) + 1
		if str(c.get("action", "")) != "sleeping":
			awake += 1
			actions[str(c.get("action", "idle")).get_slice(" to ", 0)] = true   # "walking to X" is one activity, not one per destination
	out.mean_mood = snappedf(mood_sum / maxf(1.0, float(n)), 0.001)
	out.activity_diversity = snappedf(float(actions.size()) / maxf(1.0, float(awake)), 0.001)
	out.jobs = jobs
	# feature echo: citizens whose memories mention something introduced in the last ECHO_DAYS sim days
	var since := int(state.get("tick", 0)) - ECHO_DAYS * Clock.TICKS_PER_DAY
	var recent: Array = []
	for b in state.get("map", {}).get("buildings", []):
		if int(b.get("built_tick", 0)) >= since and str(b.get("name", "")) != "":
			recent.append(str(b.name))
	for c in living:
		if int(c.get("arrived_tick", 0)) > 0 and int(c.get("arrived_tick", 0)) >= since:
			recent.append(str(c.name))
	var echo := 0
	for c in living:
		for m in c.get("memories", []):
			var text := str(m.get("text", ""))
			var hit := false
			for name in recent:
				if text.contains(name):
					hit = true
					break
			if hit:
				echo += 1
				break
	out.feature_echo = echo
	out.recent_features = recent.size()
	return out
