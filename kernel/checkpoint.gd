# KERNEL — frozen. Checkpoint format v1 + migration contract.
# A checkpoint is the whole world state as one JSON document. Loading merges DEFAULTS so that
# any field added later has a value in old checkpoints. Numbers come back from JSON as floats;
# whole floats are coerced to int so tick arithmetic stays exact.
extends RefCounted

const VERSION := 1

static func save(state: Dictionary, path: String) -> Error:
	state["version"] = VERSION
	state["saved_at"] = int(Time.get_unix_time_from_system())
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("checkpoint: cannot open %s (%s)" % [tmp, FileAccess.get_open_error()])
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(state, "", false))
	f.close()
	return DirAccess.rename_absolute(tmp, path)

# defaults: {"": state_defaults, "citizens[]": citizen_defaults, "map.buildings[]": ...}
static func load(path: String, defaults: Dictionary) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("checkpoint: %s is not a JSON object" % path)
		return {}
	var state: Dictionary = fix_numbers(parsed)
	return migrate(state, defaults)

static func migrate(state: Dictionary, defaults: Dictionary) -> Dictionary:
	var v := int(state.get("version", 1))
	# Per-version steps go here, in order, each bumping v. v1 is the seed format.
	state["version"] = VERSION
	for spec_path in defaults:
		apply_defaults(state, spec_path, defaults[spec_path])
	return state

static func apply_defaults(root: Dictionary, spec_path: String, dflt: Dictionary) -> void:
	if spec_path == "":
		merge_defaults(root, dflt)
		return
	var parts := spec_path.split(".")
	var targets: Array = [root]
	for part in parts:
		var each := part.ends_with("[]")
		var key := part.trim_suffix("[]")
		var next: Array = []
		for t in targets:
			if typeof(t) != TYPE_DICTIONARY or not t.has(key):
				continue
			var v = t[key]
			if each and typeof(v) == TYPE_ARRAY:
				for e in v:
					if typeof(e) == TYPE_DICTIONARY:
						next.append(e)
			elif not each and typeof(v) == TYPE_DICTIONARY:
				next.append(v)
		targets = next
	for t in targets:
		merge_defaults(t, dflt)

static func merge_defaults(d: Dictionary, dflt: Dictionary) -> void:
	for k in dflt:
		if not d.has(k):
			d[k] = dflt[k].duplicate(true) if typeof(dflt[k]) in [TYPE_DICTIONARY, TYPE_ARRAY] else dflt[k]

static func fix_numbers(v):
	match typeof(v):
		TYPE_FLOAT:
			return int(v) if v == floor(v) and absf(v) < 9.0e15 else v
		TYPE_DICTIONARY:
			for k in v:
				v[k] = fix_numbers(v[k])
			return v
		TYPE_ARRAY:
			for i in v.size():
				v[i] = fix_numbers(v[i])
			return v
	return v

# Canonical text of a state: a JSON round-trip so int/float representation cannot differ.
static func canonical(state: Dictionary) -> String:
	var copy: Dictionary = state.duplicate(true)
	copy.erase("saved_at")
	return JSON.stringify(JSON.parse_string(JSON.stringify(copy)))

static func hash_state(state: Dictionary) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(canonical(state).to_utf8_buffer())
	return ctx.finish().hex_encode()
