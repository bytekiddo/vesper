# KERNEL — frozen. Budget ledger: append-only JSONL, one line per LLM call, shared with overseers/rails.py.
# The month's budget (BUDGET_USD_PER_MONTH) is split into categories by config/budget.json; every line carries one.
extends RefCounted

const DEFAULTS := {"default_usd_per_month": 400.0, "range_usd": [300.0, 500.0],
	"split": {"overseers": 0.5, "citizens": 0.3, "art": 0.1, "judge": 0.1}}
static var _cfg := {}

static func root() -> String:
	return ProjectSettings.globalize_path("res://")

static func path() -> String:
	return root() + "ledger/spend.jsonl"

## DEFAULTS overlaid with config/budget.json (mirrors rails.budget_config)
static func config() -> Dictionary:
	if _cfg.is_empty():
		_cfg = DEFAULTS.duplicate(true)
		var p := root() + "config/budget.json"
		if FileAccess.file_exists(p):
			var c = JSON.parse_string(FileAccess.get_file_as_string(p))
			if typeof(c) == TYPE_DICTIONARY:
				_cfg.merge(c, true)
	return _cfg

static func budget() -> float:
	var c := config()
	var b := float(c.default_usd_per_month)
	if OS.has_environment("BUDGET_USD_PER_MONTH"):
		b = float(OS.get_environment("BUDGET_USD_PER_MONTH"))
	return clampf(b, float(c.range_usd[0]), float(c.range_usd[1]))

## share of the month for a category: overseers | citizens | art | judge
static func share(category: String) -> float:
	return float(config().split.get(category, 0.0))

## category of a ledger line that predates the field (mirrors rails.category_of)
static func category_of(source: String, role: String) -> String:
	if source == "server":
		return "citizens"
	return "judge" if role in ["judge", "verifier"] else "overseers"

static func month_key(unix: int = -1) -> String:
	if unix < 0:
		unix = int(Time.get_unix_time_from_system())
	var d := Time.get_datetime_dict_from_unix_time(unix)
	return "%04d-%02d" % [d.year, d.month]

static func append(source: String, role: String, model: String, prompt_tokens: int, completion_tokens: int, cost_usd: float, category: String = "") -> void:
	if category == "":
		category = category_of(source, role)
	DirAccess.make_dir_recursive_absolute(path().get_base_dir())
	var line := JSON.stringify({
		"ts": int(Time.get_unix_time_from_system()), "month": month_key(), "source": source, "role": role, "model": model,
		"category": category, "prompt_tokens": prompt_tokens, "completion_tokens": completion_tokens, "cost": cost_usd,
	})
	var f := FileAccess.open(path(), FileAccess.READ_WRITE) if FileAccess.file_exists(path()) else FileAccess.open(path(), FileAccess.WRITE)
	if f == null:
		push_error("ledger: cannot open %s" % path())
		return
	f.seek_end()
	f.store_line(line)
	f.close()

# ponytail: reads the whole file each call; fine for a few MB a month. Summarize yearly if it ever matters.
static func month_total(month: String = "") -> Dictionary:
	if month == "":
		month = month_key()
	var out := {"month": month, "cost": 0.0, "calls": 0, "prompt_tokens": 0, "completion_tokens": 0, "by_role": {}, "by_model": {}, "by_category": {}}
	if not FileAccess.file_exists(path()):
		return out
	var f := FileAccess.open(path(), FileAccess.READ)
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "":
			continue
		var e = JSON.parse_string(line)
		if typeof(e) != TYPE_DICTIONARY or e.get("month", "") != month:
			continue
		var c := float(e.get("cost", 0.0))
		out.cost += c
		out.calls += 1
		out.prompt_tokens += int(e.get("prompt_tokens", 0))
		out.completion_tokens += int(e.get("completion_tokens", 0))
		var role := str(e.get("role", "?"))
		var model := str(e.get("model", "?"))
		var cat := str(e.get("category", category_of(str(e.get("source", "")), role)))
		out.by_role[role] = out.by_role.get(role, 0.0) + c
		out.by_model[model] = out.by_model.get(model, 0.0) + c
		out.by_category[cat] = out.by_category.get(cat, 0.0) + c
	f.close()
	return out

static func remaining(month_cost: float = -1.0) -> float:
	if month_cost < 0.0:
		month_cost = month_total().cost
	return maxf(0.0, budget() - month_cost)

static func days_left_in_month(unix: int = -1) -> float:
	if unix < 0:
		unix = int(Time.get_unix_time_from_system())
	var d := Time.get_datetime_dict_from_unix_time(unix)
	var next_month := {"year": d.year + (1 if d.month == 12 else 0), "month": 1 if d.month == 12 else d.month + 1, "day": 1, "hour": 0, "minute": 0, "second": 0}
	var end := Time.get_unix_time_from_datetime_dict(next_month)
	return maxf(0.5, float(end - unix) / 86400.0)
