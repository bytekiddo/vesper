# KERNEL — frozen. Content limits, enforced on every LLM output before it touches world state.
# Violations are quarantined to quarantine/<date>.jsonl and never written into the world.
extends RefCounted

const Ledger = preload("res://kernel/ledger.gd")

static var _rules: Dictionary = {}
static var _compiled: Dictionary = {}

static func rules() -> Dictionary:
	if _rules.is_empty():
		var text := FileAccess.get_file_as_string("res://kernel/content_rules.json")
		_rules = JSON.parse_string(text)
		for key in ["sexual", "minor_terms", "romance_terms", "harm", "slurs"]:
			var arr: Array = []
			for pat in _rules.get(key, []):
				var re := RegEx.new()
				if re.compile("(?i)" + pat) == OK:
					arr.append(re)
			_compiled[key] = arr
	return _rules

static func _any(key: String, text: String) -> bool:
	rules()
	for re in _compiled.get(key, []):
		if re.search(text) != null:
			return true
	return false

# Returns {"ok": bool, "reason": String}. `text` is any LLM output about to enter world state.
static func check(text: String) -> Dictionary:
	if text.length() > 20000:
		return {"ok": false, "reason": "length"}
	if _any("slurs", text):
		return {"ok": false, "reason": "slur"}
	if _any("sexual", text):
		return {"ok": false, "reason": "sexual"}
	if _any("harm", text):
		return {"ok": false, "reason": "harm"}
	for sentence in text.split(".", false):
		for piece in sentence.split("\n", false):
			if _any("minor_terms", piece) and _any("romance_terms", piece):
				return {"ok": false, "reason": "minor_romance"}
	var names := check_names(text)
	if not names.ok:
		return names
	return {"ok": true, "reason": ""}

static var _name_res: Array = []

# Real persons and brands may not appear in the town. Whole-word, case-insensitive match on the deny lists.
static func check_names(text: String) -> Dictionary:
	if _name_res.is_empty():
		for key in ["real_people", "brands"]:
			for name in rules().get(key, []):
				var re := RegEx.new()
				var pat := ""
				for ch in str(name):
					pat += ("\\" + ch) if ch in ".-+()[]{}^$|?*\\" else ch
				if re.compile("(?i)(?<![\\w])" + pat + "(?![\\w])") == OK:
					_name_res.append([re, key + ":" + str(name)])
	for entry in _name_res:
		if entry[0].search(text) != null:
			return {"ok": false, "reason": entry[1]}
	return {"ok": true, "reason": ""}

# Structural rule: no romantic/sexual relationship edge may involve anyone under adult_age.
static func check_relationship(kind: String, age_a: float, age_b: float) -> Dictionary:
	var adult := float(rules().get("adult_age", 18))
	if kind in ["partner", "romantic", "lover", "spouse", "crush", "flirt"] and (age_a < adult or age_b < adult):
		return {"ok": false, "reason": "minor_romance_edge"}
	return {"ok": true, "reason": ""}

static func quarantine(text: String, reason: String, source: String) -> void:
	var dir := Ledger.root() + "quarantine"
	DirAccess.make_dir_recursive_absolute(dir)
	var day := Time.get_date_string_from_system(true)
	var p := dir + "/" + day + ".jsonl"
	var f := FileAccess.open(p, FileAccess.READ_WRITE) if FileAccess.file_exists(p) else FileAccess.open(p, FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line(JSON.stringify({"ts": int(Time.get_unix_time_from_system()), "source": source, "reason": reason, "text": text.left(4000)}))
	f.close()

# Filter + quarantine in one step. Returns true when the text may enter world state.
static func admit(text: String, source: String) -> bool:
	var r := check(text)
	if not r.ok:
		quarantine(text, r.reason, source)
		push_warning("content filter quarantined %s output (%s)" % [source, r.reason])
	return r.ok

static func quarantine_count_today() -> int:
	var p := Ledger.root() + "quarantine/" + Time.get_date_string_from_system(true) + ".jsonl"
	if not FileAccess.file_exists(p):
		return 0
	var n := 0
	for line in FileAccess.get_file_as_string(p).split("\n"):
		if line.strip_edges() != "":
			n += 1
	return n
