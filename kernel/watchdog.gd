# KERNEL — frozen. Self-hash, memory ceiling, drift accounting, boot-health signal for guard.sh.
extends RefCounted

const Ledger = preload("res://kernel/ledger.gd")

const MEMORY_CEILING_MB := 768.0
const MAX_DRIFT_MS := 1000.0
const HEALTHY_AFTER_SEC := 600.0

static func root() -> String:
	return Ledger.root()

# Compares every file listed in kernel/KERNEL.sha256 (sha256sum format) with its current hash.
static func verify_kernel() -> bool:
	var manifest := root() + "kernel/KERNEL.sha256"
	if not FileAccess.file_exists(manifest):
		push_error("watchdog: kernel/KERNEL.sha256 missing")
		return false
	var ok := true
	for line in FileAccess.get_file_as_string(manifest).split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var parts := line.split(" ", false)
		if parts.size() < 2:
			continue
		var want := parts[0]
		var rel := parts[parts.size() - 1].trim_prefix("*")
		var got := FileAccess.get_sha256(root() + rel)
		if got != want:
			push_error("watchdog: kernel file modified: %s" % rel)
			ok = false
	return ok

static func memory_mb() -> float:
	return float(OS.get_static_memory_usage()) / (1024.0 * 1024.0)

static func memory_ok() -> bool:
	return memory_mb() < MEMORY_CEILING_MB

static func mark_healthy() -> void:
	DirAccess.make_dir_recursive_absolute(root() + "state")
	var f := FileAccess.open(root() + "state/boot_failures", FileAccess.WRITE)
	if f:
		f.store_string("0\n")
		f.close()

static func write_metrics(m: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(root() + "state")
	m["memory_mb"] = snappedf(memory_mb(), 0.1)
	m["ts"] = int(Time.get_unix_time_from_system())
	var f := FileAccess.open(root() + "state/metrics.json", FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(m, "  "))
		f.close()
