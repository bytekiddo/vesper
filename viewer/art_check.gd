# Headless image checks for viewer/art, run by overseers/pixellab.py (make art-check / art-eval). Prints ONE JSON line.
#   godot --headless --path . -s viewer/art_check.gd -- --palette viewer/art/style_ref.png
#   godot --headless --path . -s viewer/art_check.gd -- --check viewer/art/citizens/x/south.png ...
# The style check: every opaque pixel must sit within `tolerance` (max channel distance) of a palette colour for at
# least `min_share` of the pixels, and no pixel may be the viewer's magenta placeholder.
extends SceneTree

const MAX_COLOURS := 80   # style ref + two tilesets; a 4-bit-quantised palette this size is still one shared palette

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var out := {}
	if args.size() >= 2 and args[0] == "--palette":
		out = {"palette": extract_palette(args.slice(1))}
	elif args.size() >= 2 and args[0] == "--check":
		var cfg := palette_config()
		out = {"files": {}}
		for i in range(1, args.size()):
			out.files[args[i]] = check(args[i], cfg)
	else:
		out = {"error": "usage: --palette <png> | --check <png>..."}
	print(JSON.stringify(out))
	quit(0)

func abs_path(rel: String) -> String:
	return rel if rel.begins_with("/") else ProjectSettings.globalize_path("res://") + rel

func palette_config() -> Dictionary:
	var p := abs_path("viewer/art/palette.json")
	var cfg := {"palette": [], "tolerance": 40, "min_share": 0.9}
	if FileAccess.file_exists(p):
		var d = JSON.parse_string(FileAccess.get_file_as_string(p))
		if typeof(d) == TYPE_DICTIONARY:
			cfg.merge(d, true)
	return cfg

func load_image(rel: String) -> Image:
	var img := Image.new()
	return img if img.load(abs_path(rel)) == OK else null

## the most frequent opaque colours across the given files, quantised to 4 bits per channel
func extract_palette(rels: Array) -> Array:
	var counts := {}
	for rel in rels:
		var img := load_image(str(rel))
		if img == null:
			continue
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				if c.a < 0.5:
					continue
				var q := Color(floorf(c.r * 15.0) / 15.0, floorf(c.g * 15.0) / 15.0, floorf(c.b * 15.0) / 15.0)
				var h := q.to_html(false)
				counts[h] = int(counts.get(h, 0)) + 1
	var keys := counts.keys()
	keys.sort_custom(func(a, b): return counts[a] > counts[b])
	var pal: Array = []
	for k in keys.slice(0, MAX_COLOURS):
		pal.append("#" + k)
	return pal

func check(rel: String, cfg: Dictionary) -> Dictionary:
	var img := load_image(rel)
	if img == null:
		return {"ok": false, "why": "cannot load"}
	var pal: Array = []
	for h in cfg.palette:
		pal.append(Color(str(h)))
	var tol := float(cfg.tolerance) / 255.0
	var opaque := 0
	var near := 0
	var magenta := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a < 0.5:
				continue
			opaque += 1
			if c.r > 0.9 and c.b > 0.9 and c.g < 0.1:
				magenta += 1
			var best := 9.0
			for p in pal:
				best = minf(best, maxf(absf(c.r - p.r), maxf(absf(c.g - p.g), absf(c.b - p.b))))
				if best <= tol:
					break
			if best <= tol:
				near += 1
	var share := float(near) / maxf(1.0, float(opaque))
	var ok := magenta == 0 and (pal.is_empty() or share >= float(cfg.min_share))
	return {"ok": ok, "share": snappedf(share, 0.001), "magenta": magenta, "opaque": opaque, "size": [img.get_width(), img.get_height()]}
