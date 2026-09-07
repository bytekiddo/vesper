# Entity defaults. THE MIGRATION CONTRACT: every serialized field has a default here, so any
# checkpoint from any era loads. Add a field => add its default. Never remove a default.
extends RefCounted

const STATE := {
	"version": 1, "seed": 7, "tick": 0, "next_id": 100,
	"map": {}, "citizens": [], "events": [], "history": [],
	"journal": {"name": "", "tone": ""},
	"season": "spring", "weather": "clear", "weather_since": 0,
	"stats": {"births": 0, "deaths": 0, "arrivals": 0, "departures": 0, "conversations": 0, "tier2_calls": 0, "tier2_applied": 0, "needs": [], "visits": 0},
	"inbox_applied": [], "map_version": 0, "last_daily_sample": -1, "rules_hash": "",
}

const MAP := {
	"w": 48, "h": 36, "tiles": "", "water": [], "streets": [], "buildings": [], "origin_x": 0, "origin_y": 0,
}

const BUILDING := {
	"id": 0, "name": "", "kind": "house", "x": 0, "y": 0, "w": 3, "h": 2, "door": [0, 0], "capacity": 4,
	"open": false, "residents": [], "built_tick": 0, "note": "",
}

const STREET := {"name": "", "x": 0, "y": 0, "w": 1, "h": 1, "built_tick": 0}

const CITIZEN := {
	"id": 0, "name": "", "age": 30.0, "pronouns": "they/them", "innate": "", "learned": "", "lifestyle": "", "currently": "",
	"occupation": "", "home": 0, "work": 0, "x": 0, "y": 0, "path": [], "goal": [-1, -1],
	"mood": "calm", "thought": "", "action": "idle", "place": 0, "block": -1, "facing": "south",
	"routine": [], "plan": [], "plan_day": -1,
	"memories": [], "relationships": {}, "last_reflect_tick": 0, "imp_since_reflect": 0,
	"conv": {}, "last_conv_tick": -100000, "last_conscious_tick": -100000,
	"alive": true, "arrived_tick": 0, "color": "#c9a86b", "sprite": 0, "parents": [], "visitor": false, "expires_tick": 0,
}

const MEMORY := {"t": 0, "kind": "obs", "text": "", "imp": 1, "last": 0, "cites": []}

# Path spec consumed by kernel/checkpoint.gd
static func defaults() -> Dictionary:
	return {
		"": STATE, "stats": STATE.stats, "map": MAP, "map.buildings[]": BUILDING, "map.streets[]": STREET,
		"citizens[]": CITIZEN, "citizens[].memories[]": MEMORY,
	}
