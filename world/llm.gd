# OpenRouter client for citizen consciousness. Server-side only; the viewer never loads this.
# Every call: budget check before, ledger line after, content filter on apply. Stub mode = no network.
extends Node

const Ledger = preload("res://kernel/ledger.gd")
const Cognition = preload("res://world/cognition.gd")

const URL := "https://openrouter.ai/api/v1/chat/completions"
const POOL := 4

var stub := false
var catching_up := false
var api_key := ""
var model := "openai/gpt-oss-120b"
var price_in := 0.037e-6     # USD per prompt token
var price_out := 0.17e-6     # USD per completion token
var results: Array = []      # {kind, cid, ctx, text, tick}
var pending := {}            # HTTPRequest -> meta
var idle: Array = []
var citizen_month_cost := 0.0
var visitor_month_cost := 0.0   # the "visitor" ledger category: a separate, smaller purse for people who walk in
var spent_today := 0.0
var day_key := ""
var last_ledger_sync := 0.0
var last_config_load := 0.0
var calls_this_tick := 0
var tick_of_calls := -1
var errors := 0

func _ready() -> void:
	api_key = OS.get_environment("OPENROUTER_API_KEY")
	for i in POOL:
		var r := HTTPRequest.new()
		r.timeout = 90.0
		r.use_threads = false
		add_child(r)
		r.request_completed.connect(_on_completed.bind(r))
		idle.append(r)
	load_config()
	sync_ledger()

func load_config() -> void:
	last_config_load = Time.get_unix_time_from_system()
	var path := Ledger.root() + "config/models.json"
	if not FileAccess.file_exists(path):
		return
	var cfg = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(cfg) != TYPE_DICTIONARY or typeof(cfg.get("citizen")) != TYPE_DICTIONARY:
		return
	model = str(cfg.citizen.get("model", model))
	price_in = float(cfg.citizen.get("prompt", price_in))
	price_out = float(cfg.citizen.get("completion", price_out))

func sync_ledger() -> void:
	last_ledger_sync = Time.get_unix_time_from_system()
	var t := Ledger.month_total()
	citizen_month_cost = 0.0
	for role in t.by_role:
		if str(role).begins_with("citizen"):
			citizen_month_cost += float(t.by_role[role])
	visitor_month_cost = float(t.by_category.get("visitor", 0.0))
	citizen_month_cost -= visitor_month_cost
	var today := Time.get_date_string_from_system(true)
	if today != day_key:
		day_key = today
		spent_today = 0.0

func est_cost() -> float:
	return 1800.0 * price_in + 350.0 * price_out

func allowance_today() -> float:
	var share := Ledger.budget() * Ledger.share("citizens")
	return maxf(0.0, (share - citizen_month_cost) / Ledger.days_left_in_month())

func can_afford() -> bool:
	return spent_today + est_cost() <= allowance_today() and Ledger.remaining(citizen_month_cost) > est_cost()

func can_afford_visitor() -> bool:
	return visitor_month_cost + est_cost() <= Ledger.budget() * Ledger.share("visitor") and Ledger.remaining() > est_cost()

func status() -> Dictionary:
	return {"model": model, "budget": Ledger.budget(), "citizen_spent_month": snappedf(citizen_month_cost, 0.0001), "spent_today": snappedf(spent_today, 0.0001),
		"allowance_today": snappedf(allowance_today(), 0.0001), "est_cost_per_call": snappedf(est_cost(), 0.00001), "stub": stub, "pending": pending.size(), "errors": errors}

# Returns true when a Tier 2 request was made (the citizen becomes "conscious" now).
func request(kind: String, state: Dictionary, c: Dictionary, ctx: Dictionary, tick: int) -> bool:
	if tick != tick_of_calls:
		tick_of_calls = tick
		calls_this_tick = 0
	var max_per_tick := int(preload("res://world/sim.gd").R().get("consciousness", {}).get("max_calls_per_tick", 2))
	if calls_this_tick >= max_per_tick:
		return false
	if stub:
		calls_this_tick += 1
		results.append({"kind": kind, "cid": int(c.id), "ctx": ctx, "text": Cognition.stub(kind, state, c, ctx, tick), "tick": tick})
		state.stats.tier2_calls = int(state.stats.tier2_calls) + 1
		return true
	if catching_up or api_key == "" or idle.is_empty() or not (can_afford_visitor() if kind == "visit" else can_afford()):
		return false
	var p := Cognition.prompt(kind, state, c, ctx, tick)
	var body := JSON.stringify({"model": model, "max_tokens": p.max_tokens, "temperature": 0.8,
		"response_format": {"type": "json_object"},
		"messages": [{"role": "system", "content": p.system}, {"role": "user", "content": p.user}]})
	var r: HTTPRequest = idle.pop_back()
	var err := r.request(URL, ["Authorization: Bearer " + api_key, "Content-Type: application/json", "HTTP-Referer: https://github.com/bytekiddo/vesper", "X-Title: Vesper"], HTTPClient.METHOD_POST, body)
	if err != OK:
		idle.append(r)
		errors += 1
		return false
	pending[r] = {"kind": kind, "cid": int(c.id), "ctx": ctx, "tick": tick}
	calls_this_tick += 1
	spent_today += est_cost()   # provisional; corrected when usage arrives
	state.stats.tier2_calls = int(state.stats.tier2_calls) + 1
	return true

func _on_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, r: HTTPRequest) -> void:
	var meta: Dictionary = pending.get(r, {})
	pending.erase(r)
	idle.append(r)
	if meta.is_empty():
		return
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		errors += 1
		push_warning("llm: request failed result=%d code=%d %s" % [result, code, body.get_string_from_utf8().left(200)])
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if typeof(data) != TYPE_DICTIONARY:
		errors += 1
		return
	var usage: Dictionary = data.get("usage", {})
	var pt := int(usage.get("prompt_tokens", 0))
	var ct := int(usage.get("completion_tokens", 0))
	var cost: float = float(usage.get("cost", pt * price_in + ct * price_out))
	if meta.kind == "visit":
		visitor_month_cost += cost
		spent_today -= est_cost()   # the visitor purse, not the citizens' day
		Ledger.append("server", "citizen:" + meta.kind, str(data.get("model", model)), pt, ct, cost, "visitor")
	else:
		spent_today += cost - est_cost()
		citizen_month_cost += cost
		Ledger.append("server", "citizen:" + meta.kind, str(data.get("model", model)), pt, ct, cost)
	var choices: Array = data.get("choices", [])
	if choices.is_empty():
		return
	var text := str(choices[0].get("message", {}).get("content", ""))
	results.append({"kind": meta.kind, "cid": meta.cid, "ctx": meta.ctx, "text": text, "tick": meta.tick})

func drain() -> Array:
	var out := results
	results = []
	return out

func housekeeping() -> void:
	var now := Time.get_unix_time_from_system()
	if now - last_ledger_sync > 300.0:
		sync_ledger()
	if now - last_config_load > 600.0:
		load_config()
