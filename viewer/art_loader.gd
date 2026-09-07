# Loads viewer/art/manifest.json (written by overseers/pixellab.py) into textures and SpriteFrames, lazily.
# Anything missing returns null; callers keep their procedural fallback so the viewer works with no art at all.
extends RefCounted

var manifest := {}
var tex := {}      # rel -> Texture2D (or null once looked up)
var frames := {}   # citizen key -> SpriteFrames (or null)

func _init() -> void:
	var p := "res://viewer/art/manifest.json"
	if FileAccess.file_exists(p):
		var d = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(d) == TYPE_DICTIONARY:
			manifest = d

static func slug(name: String) -> String:
	var re := RegEx.new()
	re.compile("[^a-z0-9]+")
	return re.sub(name.to_lower(), "-", true).trim_prefix("-").trim_suffix("-")

func has_art() -> bool:
	return not manifest.is_empty()

func texture(rel: String) -> Texture2D:
	if rel == "":
		return null
	if tex.has(rel):
		return tex[rel]
	var t: Texture2D = null
	var path := "res://viewer/art/" + rel
	if ResourceLoader.exists(path):
		t = load(path)
	elif FileAccess.file_exists(path):   # not imported yet (fresh asset on a dev machine): load the PNG directly
		var img := Image.new()
		if img.load(ProjectSettings.globalize_path(path)) == OK:
			t = ImageTexture.create_from_image(img)
	tex[rel] = t
	return t

## SpriteFrames with idle_<dir> and walk_<dir> for the four directions; the plain rotation stands in for a missing animation
func citizen_frames(key: String) -> SpriteFrames:
	if frames.has(key):
		return frames[key]
	var c: Dictionary = manifest.get("citizens", {}).get(key, {})
	if c.is_empty():
		frames[key] = null
		return null
	var sf := SpriteFrames.new()
	sf.remove_animation("default")
	for dir: String in ["south", "north", "east", "west"]:
		var rot := texture(str(c.get("rotations", {}).get(dir, "")))
		for anim: String in ["idle", "walk"]:
			var an: String = anim + "_" + dir
			sf.add_animation(an)
			sf.set_animation_speed(an, 8.0 if anim == "walk" else 3.0)
			for rel in c.get("animations", {}).get(anim, {}).get(dir, []):
				var t := texture(str(rel))
				if t:
					sf.add_frame(an, t)
			if sf.get_frame_count(an) == 0 and rot:
				sf.add_frame(an, rot)
	frames[key] = sf
	return sf

## the citizen's own sprite, else the shared default villager, else null (procedural)
func frames_for(name: String) -> SpriteFrames:
	var sf := citizen_frames(slug(name))
	return sf if sf else citizen_frames("default")

func building(kind: String, w: int, h: int) -> Texture2D:
	return texture(str(manifest.get("buildings", {}).get("%s_%dx%d" % [kind, w, h], "")))

## corner-key ("NW+SE", "none", ...) -> Texture2D for a dual-grid terrain set
func tileset(name: String) -> Dictionary:
	var out := {}
	var ts: Dictionary = manifest.get("tilesets", {}).get(name, {})
	for k in ts.get("tiles", {}):
		var t := texture(str(ts.tiles[k]))
		if t:
			out[k] = t
	return out
