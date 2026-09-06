# KERNEL — frozen. Canonical time. Tick n is due at genesis + n * TICK_SECONDS, always.
extends RefCounted

const GENESIS_ISO := "2026-09-07T00:00:00"   # UTC. Never change.
const TICK_SECONDS := 1.0                     # Never change.
const SIM_SECONDS_PER_TICK := 10              # Never change. One sim day = 8640 ticks = 2.4 real hours.
const TICKS_PER_DAY := 86400 / SIM_SECONDS_PER_TICK
const WEEKDAYS := ["Moonday", "Tideday", "Wendsday", "Thornday", "Fireday", "Saltday", "Sunday"]
const MONTHS := ["Thaw", "Sprout", "Bloom", "Haze", "Gleam", "Ember", "Reap", "Rust", "Mist", "Frost", "Hush", "Lantern"]
const DAYS_PER_MONTH := 30

static func genesis_unix() -> int:
	return int(Time.get_unix_time_from_datetime_string(GENESIS_ISO))

static func tick_for(unix: float, genesis: int = -1) -> int:
	if genesis < 0:
		genesis = genesis_unix()
	return int(floor((unix - genesis) / TICK_SECONDS))

static func tick_now(genesis: int = -1) -> int:
	return tick_for(Time.get_unix_time_from_system(), genesis)

static func due_unix(tick: int, genesis: int = -1) -> float:
	if genesis < 0:
		genesis = genesis_unix()
	return float(genesis) + tick * TICK_SECONDS

# Simulated calendar for a tick. Pure function; the viewer and the server agree by construction.
static func sim(tick: int) -> Dictionary:
	var day := int(tick / TICKS_PER_DAY)
	var sec := (tick % TICKS_PER_DAY) * SIM_SECONDS_PER_TICK
	var hour := int(sec / 3600)
	var minute := int((sec % 3600) / 60)
	var year := int(day / (DAYS_PER_MONTH * 12)) + 1
	var month := int((day % (DAYS_PER_MONTH * 12)) / DAYS_PER_MONTH)
	var dom := day % DAYS_PER_MONTH + 1
	return {
		"tick": tick, "day": day, "hour": hour, "minute": minute,
		"hhmm": "%02d:%02d" % [hour, minute],
		"weekday": WEEKDAYS[day % 7],
		"date": "%s %d, Year %d" % [MONTHS[month], dom, year],
		"minute_of_day": hour * 60 + minute,
	}

static func hhmm_to_minute(s: String) -> int:
	var p := s.split(":")
	if p.size() != 2:
		return 0
	return int(p[0]) * 60 + int(p[1])
