# Exercises one full seasonal cycle without waiting 36 real days: `godot --headless --path . -s world/season_cycle.gd`
# Walks a sim year of ticks through Sim.world_view (four seasons, four tints, daylight curve) and steps a fresh world
# for three sim days with a silent brain to see the weather roll. Prints one JSON line; exit 0 = ok.
extends SceneTree

const Clock = preload("res://kernel/clock.gd")
const Sim = preload("res://world/sim.gd")

func _initialize() -> void:
	var state := Sim.new_from_seed()
	var seasons := {}
	for day in range(0, Clock.DAYS_PER_MONTH * 12, 15):
		var w := Sim.world_view(state, day * Clock.TICKS_PER_DAY + 12 * 360)   # noon
		seasons[w.season] = w.tint
	var light := {}
	for h in [0, 6, 12, 19, 23]:
		light[str(h)] = Sim.world_view(state, h * 360).light
	var brain := func(_kind, _state, _c, _ctx): return false
	var weathers := {}
	var events_before: int = state.events.size()
	for i in 3 * Clock.TICKS_PER_DAY:
		Sim.step(state, i + 1, brain)
		weathers[str(state.weather)] = true
	var facings := {}
	for c in Sim.alive(state):
		facings[str(c.facing)] = true
	var ok := seasons.size() == 4 and float(light["12"]) > float(light["0"]) and weathers.size() >= 2 and facings.size() >= 2
	print(JSON.stringify({"ok": ok, "seasons": seasons, "light_by_hour": light, "weathers": weathers.keys(), "facings": facings.keys(),
		"weather_events": state.events.slice(events_before).filter(func(e): return str(e.text).findn("rain") >= 0 or str(e.text).findn("fog") >= 0 or str(e.text).findn("storm") >= 0).size()}))
	quit(0 if ok else 1)
