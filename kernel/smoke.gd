# KERNEL — frozen. The smoke test. `godot --headless --path . -s kernel/smoke.gd`
# 1 boot from seed  2 fast-run N ticks with a stubbed Tier 2  3 replay determinism  4 checkpoint round-trip
# 5 real-time run for SMOKE_SECONDS measuring drift and memory. Exit 0 = pass.
extends SceneTree

const Clock = preload("res://kernel/clock.gd")
const Checkpoint = preload("res://kernel/checkpoint.gd")
const Watchdog = preload("res://kernel/watchdog.gd")
const Ledger = preload("res://kernel/ledger.gd")
const Schema = preload("res://world/schema.gd")
const Sim = preload("res://world/sim.gd")
const Cognition = preload("res://world/cognition.gd")
const ServerScript = preload("res://world/server.gd")

const FAST_TICKS := 20000

var report := {"pass": false, "phases": {}, "errors": []}
var server: Node
var seconds := 600.0
var t_start := 0.0
var last_print := 0.0
var done := false

func fail(phase: String, why: String) -> void:
	report.errors.append("%s: %s" % [phase, why])
	report.phases[phase] = "FAIL"
	printerr("SMOKE FAIL %s: %s" % [phase, why])

func stub_brain(kind: String, state: Dictionary, c: Dictionary, ctx: Dictionary) -> bool:
	if not Cognition.can_think(c, int(state.tick)):
		return false
	Cognition.apply(kind, state, c, ctx, Cognition.stub(kind, state, c, ctx, int(state.tick)), int(state.tick))
	c.last_conscious_tick = int(state.tick)
	state.stats.tier2_calls = int(state.stats.tier2_calls) + 1
	return true

func fast_run(n: int) -> Dictionary:
	var state := Sim.new_from_seed()
	for i in n:
		Sim.step(state, i + 1, Callable(self, "stub_brain"))
	return state

func _initialize() -> void:
	if OS.has_environment("SMOKE_SECONDS"):
		seconds = float(OS.get_environment("SMOKE_SECONDS"))
	var t0 := Time.get_ticks_msec()
	# 1 kernel integrity
	if OS.get_environment("SMOKE_SKIP_HASH") != "1" and not Watchdog.verify_kernel():
		fail("kernel_hash", "manifest mismatch or missing (run `make kernel-hash` as a human)")
	else:
		report.phases["kernel_hash"] = "ok"
	# 2 boot + fast run
	var a := fast_run(FAST_TICKS)
	var ha := Checkpoint.hash_state(a)
	report.phases["fast_run"] = {"ticks": FAST_TICKS, "ms": Time.get_ticks_msec() - t0, "pop": Sim.alive(a).size(), "buildings": a.map.buildings.size(),
		"conversations": a.stats.conversations, "tier2_calls": a.stats.tier2_calls, "tier2_applied": a.stats.tier2_applied, "events": a.events.size(),
		"memories_total": a.citizens.reduce(func(acc, c): return acc + c.memories.size(), 0)}
	if int(a.stats.conversations) == 0 or int(a.stats.tier2_applied) == 0:
		fail("fast_run", "world is inert: no conversations or no Tier 2 applications")
	# 3 determinism
	var b := fast_run(FAST_TICKS)
	var hb := Checkpoint.hash_state(b)
	if ha != hb:
		fail("determinism", "two runs from the seed diverged (%s vs %s)" % [ha.left(12), hb.left(12)])
	else:
		report.phases["determinism"] = "ok " + ha.left(12)
	# 4 checkpoint round-trip + replay from a checkpoint
	var p := Ledger.root() + "state/smoke/checkpoints/roundtrip.json"
	Checkpoint.save(a, p)
	var loaded := Checkpoint.load(p, Schema.defaults())
	if loaded.is_empty() or Checkpoint.hash_state(loaded) != ha:
		fail("checkpoint", "round-trip changed the state")
	else:
		# continue both for 500 ticks: the loaded copy must track the original
		for i in 500:
			Sim.step(a, FAST_TICKS + i + 1, Callable(self, "stub_brain"))
			Sim.step(loaded, FAST_TICKS + i + 1, Callable(self, "stub_brain"))
		if Checkpoint.hash_state(a) != Checkpoint.hash_state(loaded):
			fail("checkpoint", "replay from checkpoint diverged from the live state")
		else:
			report.phases["checkpoint"] = "ok"
	# 5 real-time server
	server = ServerScript.new()
	server.smoke_mode = true
	root.add_child(server)
	t_start = Time.get_unix_time_from_system()
	print("smoke: phases 1-4 done in %d ms; real-time phase for %.0f s" % [Time.get_ticks_msec() - t0, seconds])

func _process(_delta: float) -> bool:
	if done or server == null:
		return done
	var now := Time.get_unix_time_from_system()
	if now - last_print >= 30.0:
		last_print = now
		print("smoke: t=%.0fs tick=%d drift_max=%.0fms mem=%.0fMB caught_up=%s" % [now - t_start, int(server.state.tick), float(server.metrics.drift_ms_max_window), Watchdog.memory_mb(), server.metrics.caught_up])
	if server.start_error != "":
		fail("realtime", server.start_error)
		return finish()
	if now - t_start < seconds:
		return false
	var drift := maxf(float(server.metrics.drift_ms_max_window), float(server.metrics.drift_ms_max))
	report.phases["realtime"] = {"seconds": seconds, "ticks": server.metrics.ticks, "drift_ms_max": snappedf(drift, 1.0), "memory_mb": snappedf(Watchdog.memory_mb(), 0.1), "caught_up": server.metrics.caught_up}
	if not server.metrics.caught_up:
		fail("realtime", "never caught up with the wall clock")
	if drift > Watchdog.MAX_DRIFT_MS:
		fail("realtime", "tick drift %.0f ms > %.0f ms" % [drift, Watchdog.MAX_DRIFT_MS])
	if not Watchdog.memory_ok():
		fail("realtime", "memory %.0f MB over ceiling" % Watchdog.memory_mb())
	var expected := Clock.tick_for(now, server.genesis)
	if absi(int(server.state.tick) - expected) > 2:
		fail("realtime", "tick %d but wall clock says %d" % [int(server.state.tick), expected])
	return finish()

func finish() -> bool:
	done = true
	report.pass = report.errors.is_empty()
	var out := Ledger.root() + "state/smoke/report.json"
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	var f := FileAccess.open(out, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(report, "  "))
		f.close()
	print(JSON.stringify(report, "  "))
	print("SMOKE %s" % ("PASS" if report.pass else "FAIL"))
	quit(0 if report.pass else 1)
	return true
