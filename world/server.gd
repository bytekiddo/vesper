# Headless world server: canonical clock, catch-up, checkpoints, inbox, metrics, viewer feed.
extends Node

const Clock = preload("res://kernel/clock.gd")
const Checkpoint = preload("res://kernel/checkpoint.gd")
const Ledger = preload("res://kernel/ledger.gd")
const Watchdog = preload("res://kernel/watchdog.gd")
const Filter = preload("res://kernel/content_filter.gd")
const Schema = preload("res://world/schema.gd")
const Sim = preload("res://world/sim.gd")
const Map = preload("res://world/map.gd")
const Memory = preload("res://world/memory.gd")
const Cognition = preload("res://world/cognition.gd")
const LlmScript = preload("res://world/llm.gd")
const NetScript = preload("res://world/net.gd")

var smoke_mode := false
var state: Dictionary = {}
var llm: Node
var net: Node
var genesis := 0
var port := 9001
var catching_up := false
var boot_unix := 0.0
var healthy := false
var metrics := {"drift_ms_max": 0.0, "drift_ms_max_window": 0.0, "ticks": 0, "boot_count": 0, "caught_up": false, "quarantine_today": 0}
var drift_window_start := 0.0
var last_checkpoint_tick := -1
var last_map_version := -1
var journal_cache := {"name": "", "issues": []}
var last_journal_scan := 0.0
var last_flag_check := 0.0
var start_error := ""

func root() -> String:
	return Ledger.root()

func data_dir() -> String:
	return root() + ("state/smoke/" if smoke_mode else "")

func _ready() -> void:
	boot_unix = Time.get_unix_time_from_system()
	Engine.max_fps = 30
	OS.low_processor_usage_mode = true
	_load_env()
	if not smoke_mode and not Watchdog.verify_kernel():
		start_error = "kernel hash mismatch"
		push_error("server: refusing to start — " + start_error)
		get_tree().quit(4)
		return
	genesis = int(Time.get_unix_time_from_system()) - 100 if smoke_mode else Clock.genesis_unix()
	llm = LlmScript.new()
	llm.stub = smoke_mode
	add_child(llm)
	net = NetScript.new()
	add_child(net)
	net.message.connect(_on_message)
	if smoke_mode:
		port = 9002
	elif OS.has_environment("VESPER_WS_PORT"):
		port = int(OS.get_environment("VESPER_WS_PORT"))
	net.start(port)
	_load_state()
	_bump_boot_count()
	drift_window_start = boot_unix
	print("vesper server: tick %d, genesis %d, port %d, citizens %d, smoke=%s" % [int(state.tick), genesis, port, state.citizens.size(), smoke_mode])

func _load_env() -> void:
	var p := root() + ".env"
	if not FileAccess.file_exists(p):
		return
	for line in FileAccess.get_file_as_string(p).split("\n"):
		line = line.strip_edges()
		if line == "" or line.begins_with("#") or line.find("=") < 0:
			continue
		var k := line.get_slice("=", 0).strip_edges()
		var v := line.substr(line.find("=") + 1).strip_edges().trim_prefix("\"").trim_suffix("\"")
		if not OS.has_environment(k):
			OS.set_environment(k, v)

func _load_state() -> void:
	if not smoke_mode:
		state = Checkpoint.load(root() + "checkpoints/latest.json", Schema.defaults())
		if state.is_empty():
			# git keeps the daily era files; take the newest one before falling back to the seed
			var newest := _newest_daily()
			if newest != "":
				state = Checkpoint.load(newest, Schema.defaults())
				print("server: restored from %s" % newest)
	if state.is_empty():
		state = Sim.new_from_seed()
		print("server: fresh world from seed")
	else:
		Map.rebuild(state.map)
	state.genesis_unix = genesis
	last_map_version = int(state.map_version)

func _newest_daily() -> String:
	var dir := root() + "checkpoints/daily"
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var files := Array(d.get_files())
	files = files.filter(func(f): return f.ends_with(".json"))
	files.sort()
	return dir + "/" + files[files.size() - 1] if files.size() > 0 else ""

func _bump_boot_count() -> void:
	var p := data_dir() + "state/boot_count"
	DirAccess.make_dir_recursive_absolute(p.get_base_dir())
	var n := 0
	if FileAccess.file_exists(p):
		n = int(FileAccess.get_file_as_string(p).strip_edges())
	n += 1
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f:
		f.store_string(str(n))
		f.close()
	metrics.boot_count = n

# Tier 2 gate: the sim asks, the server decides (catch-up, cadence, budget).
func brain(kind: String, st: Dictionary, c: Dictionary, ctx: Dictionary) -> bool:
	if catching_up or not Cognition.can_think(c, int(st.tick)):
		return false
	return llm.request(kind, st, c, ctx, int(st.tick))

func _process(_delta: float) -> void:
	var now := Time.get_unix_time_from_system()
	if not smoke_mode:
		# healthy after 10 minutes up, ticking or not (before genesis there are no ticks yet)
		if not healthy and now - boot_unix >= Watchdog.HEALTHY_AFTER_SEC:
			healthy = true
			Watchdog.mark_healthy()
		# graceful stop/restart: Godot has no signal handler, so systemd's ExecStop and the overseer runner drop a flag
		if now - last_flag_check >= 1.0:
			last_flag_check = now
			for flag in ["stop", "restart.flag"]:
				var fp: String = root() + "state/" + flag
				if FileAccess.file_exists(fp):
					var stale: bool = float(FileAccess.get_modified_time(fp)) < boot_unix - 2.0   # left over from before this boot
					DirAccess.remove_absolute(fp)
					if stale:
						continue
					print("server: %s requested — checkpointing and exiting" % flag)
					if int(state.tick) > 0:
						_checkpoint(int(state.tick))
					get_tree().quit(0)
					return
	var target := Clock.tick_for(now, genesis)
	var behind := target - int(state.tick)
	var threshold := int(Sim.R().get("consciousness", {}).get("catchup_threshold_ticks", 60))
	catching_up = behind > threshold
	llm.catching_up = catching_up
	llm.housekeeping()
	var n := 0
	var per_frame := 400 if catching_up else 2
	while int(state.tick) < target and n < per_frame:
		var next_tick := int(state.tick) + 1
		_apply_results()
		if not smoke_mode:
			_ingest_inbox(next_tick)
		var events: Array = Sim.step(state, next_tick, Callable(self, "brain"))
		n += 1
		metrics.ticks = int(metrics.ticks) + 1
		if not catching_up:
			var drift := (Time.get_unix_time_from_system() - Clock.due_unix(next_tick, genesis)) * 1000.0
			metrics.drift_ms_max_window = maxf(float(metrics.drift_ms_max_window), drift)
			metrics.caught_up = true
			_broadcast_tick(events)
		elif next_tick % 200 == 0:
			_broadcast_tick([])
		_housekeeping(next_tick, now)
	net.poll()

func _apply_results() -> void:
	for r in llm.drain():
		var c := Sim.citizen(state, int(r.cid))
		if c.is_empty() or not c.alive:
			continue
		Cognition.apply(str(r.kind), state, c, r.ctx, str(r.text), int(state.tick) + 1)

func _housekeeping(tick: int, now: float) -> void:
	if tick % 60 == 0:
		if now - drift_window_start >= 60.0:
			metrics.drift_ms_max = metrics.drift_ms_max_window
			metrics.drift_ms_max_window = 0.0
			drift_window_start = now
		metrics.quarantine_today = Filter.quarantine_count_today()
		metrics.tick = tick
		metrics.population = Sim.alive(state).size()
		metrics.viewers = net.count()
		metrics.catching_up = catching_up
		metrics.llm = llm.status()
		if not smoke_mode:
			Watchdog.write_metrics(metrics.duplicate(true))
		if not Watchdog.memory_ok():
			push_error("server: memory ceiling hit (%.0f MB) — checkpointing and exiting for restart" % Watchdog.memory_mb())
			_checkpoint(tick)
			get_tree().quit(3)
	if (tick % 300 == 0 or tick % Clock.TICKS_PER_DAY == 0) and tick != last_checkpoint_tick and not catching_up:
		_checkpoint(tick)
	if int(state.map_version) != last_map_version:
		last_map_version = int(state.map_version)
		net.broadcast({"type": "map", "map": _public_map()})
	if tick % 600 == 0 and not smoke_mode and now - last_journal_scan > 60.0:
		if _scan_journal():
			net.broadcast(_journal_msg())

# latest.json every 5 minutes (and after inbox ops / on stop); hourly copies (48 kept); one per sim day kept forever.
func _checkpoint(tick: int) -> void:
	last_checkpoint_tick = tick
	var base := data_dir() + "checkpoints/"
	Checkpoint.save(state, base + "latest.json")
	if tick % 3600 == 0:
		Checkpoint.save(state, base + "hourly/tick-%09d.json" % tick)
		_trim_dir(base + "hourly", 48)
	if tick % Clock.TICKS_PER_DAY == 0:
		Checkpoint.save(state, base + "daily/day-%05d.json" % int(Clock.sim(tick).day))

func _trim_dir(dir: String, keep: int) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	var files := Array(d.get_files())
	files.sort()
	while files.size() > keep:
		d.remove(files.pop_front())

# Overseer ops land in world/inbox/*.json; applied at a tick boundary, then moved to inbox/applied/.
func _ingest_inbox(tick: int) -> void:
	if tick % 30 != 0:
		return
	var dir := root() + "world/inbox"
	var d := DirAccess.open(dir)
	if d == null:
		return
	var files := Array(d.get_files()).filter(func(f): return f.ends_with(".json"))
	files.sort()
	if files.is_empty():
		return
	for f in files:
		var text := FileAccess.get_file_as_string(dir + "/" + f)
		var parsed = JSON.parse_string(text)
		var ops: Array = parsed if typeof(parsed) == TYPE_ARRAY else ([parsed] if typeof(parsed) == TYPE_DICTIONARY else [])
		var log := PackedStringArray()
		for op in ops:
			if typeof(op) != TYPE_DICTIONARY:
				continue
			var res := Sim.apply_op(state, op, tick)
			log.append("%s %s -> %s" % [f, op.get("op", "?"), res])
		DirAccess.make_dir_recursive_absolute(dir + "/applied")
		DirAccess.rename_absolute(dir + "/" + f, dir + "/applied/" + f)
		var lf := FileAccess.open(root() + "state/inbox.log", FileAccess.READ_WRITE) if FileAccess.file_exists(root() + "state/inbox.log") else FileAccess.open(root() + "state/inbox.log", FileAccess.WRITE)
		if lf:
			lf.seek_end()
			for l in log:
				lf.store_line("%d %s" % [tick, l])
			lf.close()
		state.inbox_applied.append(f)
		while state.inbox_applied.size() > 200:
			state.inbox_applied.remove_at(0)
	_checkpoint(tick)   # applied ops must survive a restart

# ---------------------------------------------------------------- viewer feed
func _on_message(peer_id: int, msg: Dictionary) -> void:
	match str(msg.get("type", "")):
		"hello":
			net.send(peer_id, _snapshot())
			net.send(peer_id, _journal_msg())
		"get_citizen":
			var c := Sim.citizen(state, int(msg.get("id", -1)))
			if not c.is_empty():
				net.send(peer_id, {"type": "citizen", "citizen": _citizen_detail(c)})

func _bubble(c: Dictionary) -> String:
	if c.conv.is_empty():
		return ""
	var lines: Array = c.conv.get("lines", [])
	if lines.is_empty():
		return ""
	var span := maxi(1, int(c.conv.until) - int(c.conv.started))
	var li := clampi(int(floor(float(int(state.tick) - int(c.conv.started)) / span * lines.size())), 0, lines.size() - 1)
	var line := str(lines[li])
	if line.begins_with(c.name + ": "):
		return line.substr(c.name.length() + 2)
	return ""

func _public_citizen(c: Dictionary, brief: bool) -> Dictionary:
	var d := {"id": int(c.id), "x": int(c.x), "y": int(c.y), "action": c.action, "thought": c.thought, "mood": c.mood, "alive": c.alive, "bubble": _bubble(c)}
	if not brief:
		d.merge({"name": c.name, "color": c.color, "sprite": int(c.sprite), "occupation": c.occupation, "age": int(c.age), "pronouns": c.pronouns})
	return d

func _public_map() -> Dictionary:
	var m: Dictionary = state.map
	var bs: Array = []
	for b in m.buildings:
		bs.append({"id": int(b.id), "name": b.name, "kind": b.kind, "x": int(b.x), "y": int(b.y), "w": int(b.w), "h": int(b.h), "door": b.door, "open": b.get("open", false), "note": b.get("note", "")})
	return {"w": int(m.w), "h": int(m.h), "tiles": m.tiles, "streets": m.streets, "buildings": bs, "version": int(state.map_version)}

func _budget_msg() -> Dictionary:
	var s: Dictionary = llm.status()
	s["month_total"] = snappedf(Ledger.month_total().cost, 0.0001) if int(state.tick) % 300 == 0 or not metrics.has("month_total") else metrics.month_total
	metrics.month_total = s.month_total
	return s

func _snapshot() -> Dictionary:
	var cs: Array = []
	for c in state.citizens:
		cs.append(_public_citizen(c, false))
	return {"type": "snapshot", "tick": int(state.tick), "clock": Clock.sim(int(state.tick)), "map": _public_map(), "citizens": cs,
		"stats": state.stats, "history": state.history.slice(maxi(0, state.history.size() - 400)), "events": state.events.slice(maxi(0, state.events.size() - 40)),
		"budget": _budget_msg(), "catching_up": catching_up, "genesis": genesis}

func _broadcast_tick(events: Array) -> void:
	if net.count() == 0:
		return
	var cs: Array = []
	for c in state.citizens:
		if c.alive:
			cs.append(_public_citizen(c, true))
	var new_names: Array = []
	for e in events:
		if int(e.imp) >= 7:
			new_names.append(e)
	net.broadcast({"type": "tick", "tick": int(state.tick), "clock": Clock.sim(int(state.tick)), "citizens": cs, "events": events,
		"budget": _budget_msg(), "stats": state.stats, "catching_up": catching_up, "population": Sim.alive(state).size(), "buildings": state.map.buildings.size(),
		"roster_changed": new_names.size() > 0})

func _citizen_detail(c: Dictionary) -> Dictionary:
	var rels: Array = []
	for key in c.relationships:
		var o := Sim.citizen(state, int(key))
		var r: Dictionary = c.relationships[key]
		rels.append({"id": int(key), "name": o.get("name", "?"), "kind": r.kind, "score": snappedf(float(r.score), 0.01), "note": r.get("note", "")})
	var mems: Array = []
	for m in Memory.recent(c, 40):
		mems.append({"t": int(m.t), "kind": m.kind, "imp": int(m.imp), "text": m.text, "when": Clock.sim(int(m.t)).date + " " + Clock.sim(int(m.t)).hhmm})
	var chats: Array = []
	for m in c.memories:
		if m.kind == "chat":
			chats.append({"when": Clock.sim(int(m.t)).date + " " + Clock.sim(int(m.t)).hhmm, "text": m.text})
	chats = chats.slice(maxi(0, chats.size() - 30))
	var sim := Clock.sim(int(state.tick))
	var today: Array = c.plan if int(c.plan_day) == int(sim.day) and c.plan.size() > 0 else c.routine
	return {"id": int(c.id), "name": c.name, "age": int(c.age), "pronouns": c.pronouns, "occupation": c.occupation, "alive": c.alive,
		"innate": c.innate, "learned": c.learned, "lifestyle": c.lifestyle, "currently": c.currently, "mood": c.mood, "thought": c.thought, "action": c.action,
		"home": Map.building(state.map, int(c.home)).get("name", ""), "work": Map.building(state.map, int(c.work)).get("name", ""),
		"plan": today, "plan_is_tier2": int(c.plan_day) == int(sim.day) and c.plan.size() > 0, "memories": mems, "relationships": rels, "conversations": chats,
		"conv": c.conv.get("lines", []) if not c.conv.is_empty() else [], "color": c.color, "sprite": int(c.sprite), "arrived": Clock.sim(int(c.arrived_tick)).date}

func _scan_journal() -> bool:
	last_journal_scan = Time.get_unix_time_from_system()
	var dir := root() + "journal"
	var d := DirAccess.open(dir)
	if d == null:
		return false
	var files := Array(d.get_files()).filter(func(f): return f.ends_with(".md") and not f.begins_with("README"))
	files.sort()
	files.reverse()
	files = files.slice(0, 12)
	var issues: Array = []
	for f in files:
		var text := FileAccess.get_file_as_string(dir + "/" + f)
		var title: String = str(f)
		for line in text.split("\n"):
			if line.begins_with("# "):
				title = line.trim_prefix("# ").strip_edges()
				break
		issues.append({"file": f, "title": title, "text": text.left(12000)})
	var name := str(state.journal.get("name", ""))
	var mast := dir + "/MASTHEAD.json"
	if FileAccess.file_exists(mast):
		var mj = JSON.parse_string(FileAccess.get_file_as_string(mast))
		if typeof(mj) == TYPE_DICTIONARY:
			name = str(mj.get("name", name))
			state.journal.name = name
			state.journal.tone = str(mj.get("tone", state.journal.tone))
	var changed: bool = issues.size() != journal_cache.issues.size() or (issues.size() > 0 and journal_cache.issues.size() > 0 and issues[0].file != journal_cache.issues[0].file) or name != journal_cache.name
	journal_cache = {"name": name, "issues": issues}
	return changed

func _journal_msg() -> Dictionary:
	if journal_cache.issues.is_empty() and Time.get_unix_time_from_system() - last_journal_scan > 60.0:
		_scan_journal()
	return {"type": "journal", "name": journal_cache.name, "issues": journal_cache.issues}

func _exit_tree() -> void:
	if not state.is_empty() and not smoke_mode and int(state.tick) > 0:
		_checkpoint(int(state.tick))
