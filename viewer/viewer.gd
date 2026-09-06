# The viewer. Connects to the world server over WebSocket, renders what it is told, simulates nothing.
extends Node

const TILE := 16
const KIND_COLORS := {"house": Color("#b98a5a"), "cafe": Color("#c86f4a"), "store": Color("#5a7fb9"), "office": Color("#8a6bb8"), "hall": Color("#4b8a6b"),
	"square": Color("#d9c9a0"), "clinic": Color("#5f9ea0"), "lighthouse": Color("#e8dcc0"), "pier": Color("#a08a6a"), "school": Color("#c9a85a"), "workshop": Color("#7a7a6a")}

var ws := WebSocketPeer.new()
var url := ""
var connected := false
var reconnect_at := 0.0
var map := {}
var citizens := {}        # id -> data
var sprites := {}         # id -> Node2D
var clock := {}
var budget := {}
var stats := {}
var history := []
var events := []
var journal := {"name": "", "issues": []}
var selected := -1
var last_detail_request := 0.0
var population := 0
var catching_up := false
var font: Font

var world: Node2D
var cam: Camera2D
var map_node: Node2D
var citizen_layer: Node2D
var hud: CanvasLayer
var top_label: Label
var status_label: Label
var events_label: Label
var panel: PanelContainer
var panel_text: RichTextLabel
var panel_title: Label
var news_panel: PanelContainer
var news_text: RichTextLabel
var news_list: ItemList
var dragging := false
var shot_path := ""      # --screenshot=<png>: save the view a few seconds after connecting, then quit (dev aid)
var shot_at := 0.0

func _ready() -> void:
	font = ThemeDB.fallback_font
	url = _pick_url()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--screenshot="):
			shot_path = a.substr(13)
		if a.begins_with("--select="):
			selected = int(a.substr(9))
	_build_scene()
	_connect()

func _pick_url() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--ws="):
			return a.substr(5)
	if OS.has_feature("web"):
		var host := str(JavaScriptBridge.eval("location.host"))
		var proto := str(JavaScriptBridge.eval("location.protocol"))
		return ("wss://" if proto == "https:" else "ws://") + host + "/ws"
	return "ws://127.0.0.1:9001"

func _connect() -> void:
	ws = WebSocketPeer.new()
	ws.inbound_buffer_size = 1 << 22
	ws.connect_to_url(url)
	connected = false
	status_label.text = "connecting to %s" % url

# ---------------------------------------------------------------- scene
func _build_scene() -> void:
	world = Node2D.new()
	add_child(world)
	map_node = Node2D.new()
	map_node.draw.connect(_draw_map)
	world.add_child(map_node)
	citizen_layer = Node2D.new()
	world.add_child(citizen_layer)
	cam = Camera2D.new()
	cam.zoom = Vector2(1.6, 1.6)
	cam.position = Vector2(24 * TILE, 18 * TILE)
	world.add_child(cam)
	cam.make_current()

	hud = CanvasLayer.new()
	add_child(hud)
	var top := PanelContainer.new()
	top.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	hud.add_child(top)
	var row := HBoxContainer.new()
	top.add_child(row)
	top_label = Label.new()
	top_label.text = "Vesper"
	top_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(top_label)
	var news_btn := Button.new()
	news_btn.text = "Newspaper"
	news_btn.pressed.connect(func(): news_panel.visible = not news_panel.visible)
	row.add_child(news_btn)
	status_label = Label.new()
	status_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	status_label.position = Vector2(8, -28)
	status_label.modulate = Color(1, 1, 1, 0.8)
	hud.add_child(status_label)
	events_label = Label.new()
	events_label.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	events_label.position = Vector2(8, -140)
	events_label.custom_minimum_size = Vector2(520, 100)
	events_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	events_label.modulate = Color(1, 1, 1, 0.85)
	hud.add_child(events_label)

	panel = PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _opaque())
	panel.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	panel.offset_left = -420
	panel.offset_top = 36
	panel.visible = false
	hud.add_child(panel)
	var pv := VBoxContainer.new()
	panel.add_child(pv)
	var ph := HBoxContainer.new()
	pv.add_child(ph)
	panel_title = Label.new()
	panel_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ph.add_child(panel_title)
	var close := Button.new()
	close.text = "x"
	close.pressed.connect(func(): selected = -1; panel.visible = false)
	ph.add_child(close)
	panel_text = RichTextLabel.new()
	panel_text.bbcode_enabled = true
	panel_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel_text.selection_enabled = true
	pv.add_child(panel_text)

	news_panel = PanelContainer.new()
	news_panel.add_theme_stylebox_override("panel", _opaque())
	news_panel.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	news_panel.offset_right = 560
	news_panel.offset_top = 36
	news_panel.offset_bottom = -150
	news_panel.visible = false
	hud.add_child(news_panel)
	var nv := VBoxContainer.new()
	news_panel.add_child(nv)
	news_list = ItemList.new()
	news_list.custom_minimum_size = Vector2(0, 120)
	news_list.item_selected.connect(_show_issue)
	nv.add_child(news_list)
	news_text = RichTextLabel.new()
	news_text.bbcode_enabled = true
	news_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	news_text.selection_enabled = true
	nv.add_child(news_text)

func _opaque() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.15, 0.96)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 8
	sb.content_margin_bottom = 8
	return sb

# ---------------------------------------------------------------- network
func _process(delta: float) -> void:
	ws.poll()
	var st := ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			ws.send_text(JSON.stringify({"type": "hello"}))
			status_label.text = "connected"
			shot_at = Time.get_unix_time_from_system() + 6.0
		while ws.get_available_packet_count() > 0:
			var v = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			if typeof(v) == TYPE_DICTIONARY:
				_handle(v)
		if selected >= 0 and Time.get_unix_time_from_system() - last_detail_request > 2.0:
			last_detail_request = Time.get_unix_time_from_system()
			ws.send_text(JSON.stringify({"type": "get_citizen", "id": selected}))
	if shot_path != "" and shot_at > 0.0 and Time.get_unix_time_from_system() > shot_at:
		shot_at = 0.0
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(shot_path)
		get_tree().quit()
	elif st == WebSocketPeer.STATE_CLOSED:
		if connected or reconnect_at == 0.0:
			connected = false
			reconnect_at = Time.get_unix_time_from_system() + 3.0
			status_label.text = "disconnected — retrying"
		elif Time.get_unix_time_from_system() > reconnect_at:
			reconnect_at = Time.get_unix_time_from_system() + 3.0
			_connect()
	for id in sprites:
		var s: Node2D = sprites[id]
		var c: Dictionary = citizens.get(id, {})
		if c.is_empty():
			continue
		var target := Vector2(int(c.x) * TILE + TILE / 2.0, int(c.y) * TILE + TILE / 2.0)
		s.position = s.position.lerp(target, minf(1.0, delta * 6.0))
		s.visible = c.get("alive", true)

func _handle(m: Dictionary) -> void:
	match str(m.get("type", "")):
		"snapshot":
			map = m.map
			citizens.clear()
			for c in m.citizens:
				citizens[int(c.id)] = c
			clock = m.clock
			budget = m.get("budget", {})
			stats = m.get("stats", {})
			history = m.get("history", [])
			events = m.get("events", [])
			catching_up = m.get("catching_up", false)
			_rebuild_sprites()
			map_node.queue_redraw()
			cam.position = Vector2(int(map.w) * TILE / 2.0, int(map.h) * TILE / 2.0)
			_update_hud()
		"tick":
			clock = m.clock
			budget = m.get("budget", budget)
			stats = m.get("stats", stats)
			catching_up = m.get("catching_up", false)
			population = int(m.get("population", population))
			var need_roster := false
			for c in m.citizens:
				var id := int(c.id)
				if citizens.has(id):
					citizens[id].merge(c, true)
				else:
					need_roster = true
			for e in m.get("events", []):
				events.append(e)
			while events.size() > 40:
				events.remove_at(0)
			if need_roster or m.get("roster_changed", false):
				ws.send_text(JSON.stringify({"type": "hello"}))
			_update_hud()
			_update_bubbles()
		"map":
			map = m.map
			map_node.queue_redraw()
		"citizen":
			_show_citizen(m.citizen)
		"journal":
			journal = m
			_update_news()

# ---------------------------------------------------------------- drawing
func _draw_map() -> void:
	if map.is_empty():
		return
	var w := int(map.w)
	var h := int(map.h)
	var tiles: String = map.tiles
	var colors := {".": Color("#6f8f5a"), "#": Color("#8c8a80"), "~": Color("#3f6f9a"), "B": Color("#6a5a4a"), "o": Color("#d9c9a0")}
	for y in h:
		for x in w:
			var t := tiles[y * w + x]
			var col: Color = colors.get(t, Color.MAGENTA)
			if t == "." and (x + y) % 2 == 0:
				col = col.darkened(0.04)
			if t == "~" and (x * 7 + y * 3) % 5 == 0:
				col = col.lightened(0.08)
			map_node.draw_rect(Rect2(x * TILE, y * TILE, TILE, TILE), col)
	for b in map.buildings:
		var r := Rect2(int(b.x) * TILE, int(b.y) * TILE, int(b.w) * TILE, int(b.h) * TILE)
		var col: Color = KIND_COLORS.get(b.kind, Color("#8a7a6a"))
		if b.get("open", false):
			map_node.draw_rect(r, col.darkened(0.1), false, 2.0)
		else:
			map_node.draw_rect(r, col)
			map_node.draw_rect(Rect2(r.position, Vector2(r.size.x, 4)), col.darkened(0.3))
			var d: Array = b.door
			map_node.draw_rect(Rect2(int(d[0]) * TILE + 5, int(d[1]) * TILE, 6, 4), Color("#3a2a1a"))
		map_node.draw_string(font, r.position + Vector2(2, -3), b.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color(1, 1, 1, 0.9))
	for s in map.streets:
		map_node.draw_string(font, Vector2(int(s.x) * TILE + 4, int(s.y) * TILE + 12), s.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 8, Color(0.15, 0.15, 0.15, 0.7))
	map_node.draw_rect(Rect2(0, 0, w * TILE, h * TILE), Color(1, 1, 1, 0.5), false, 2.0)

func _rebuild_sprites() -> void:
	for id in sprites:
		sprites[id].queue_free()
	sprites.clear()
	for id in citizens:
		var c: Dictionary = citizens[id]
		var s := Node2D.new()
		s.position = Vector2(int(c.x) * TILE + TILE / 2.0, int(c.y) * TILE + TILE / 2.0)
		s.set_meta("color", Color(str(c.get("color", "#c9a86b"))))
		s.set_meta("name", c.name)
		s.set_meta("sprite", int(c.get("sprite", 0)))
		s.draw.connect(_draw_citizen.bind(s))
		var bubble := Label.new()
		bubble.name = "Bubble"
		bubble.position = Vector2(-70, -46)
		bubble.custom_minimum_size = Vector2(140, 0)
		bubble.autowrap_mode = TextServer.AUTOWRAP_WORD
		bubble.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bubble.add_theme_font_size_override("font_size", 9)
		bubble.add_theme_color_override("font_color", Color.BLACK)
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1, 1, 0.94, 0.95)
		sb.set_corner_radius_all(4)
		sb.content_margin_left = 4
		sb.content_margin_right = 4
		sb.content_margin_top = 2
		sb.content_margin_bottom = 2
		bubble.add_theme_stylebox_override("normal", sb)
		bubble.visible = false
		s.add_child(bubble)
		citizen_layer.add_child(s)
		sprites[id] = s
	_update_bubbles()

func _draw_citizen(s: Node2D) -> void:
	var col: Color = s.get_meta("color")
	var kind: int = s.get_meta("sprite")
	s.draw_circle(Vector2(0, 6), 6.5, Color(0, 0, 0, 0.25))
	s.draw_rect(Rect2(-4, -2, 8, 9), col)
	s.draw_circle(Vector2(0, -6), 4.0, Color("#e9c9a8") if kind % 2 == 0 else Color("#c9a080"))
	if kind >= 2:
		s.draw_rect(Rect2(-4, -10, 8, 3), col.darkened(0.4))
	s.draw_string(font, Vector2(-30, 18), str(s.get_meta("name")).get_slice(" ", 0), HORIZONTAL_ALIGNMENT_CENTER, 60, 8, Color(1, 1, 1, 0.95))

func _update_bubbles() -> void:
	for id in sprites:
		var b: Label = sprites[id].get_node("Bubble")
		var text := str(citizens.get(id, {}).get("bubble", ""))
		b.visible = text != ""
		b.text = text

# ---------------------------------------------------------------- hud
func _update_hud() -> void:
	var day: String = str(clock.get("date", ""))
	var w := int(map.get("w", 0))
	var h := int(map.get("h", 0))
	var nb: int = map.get("buildings", []).size()
	var growth := ""
	if history.size() > 1:
		var first: Dictionary = history[0]
		growth = "  (day %d: %d people, %d buildings, %dx%d)" % [int(first.day), int(first.pop), int(first.buildings), int(first.w), int(first.h)]
	var spent := float(budget.get("month_total", 0.0))
	var alive := 0
	for id in citizens:
		if citizens[id].get("alive", true):
			alive += 1
	top_label.text = "  VESPER   %s %s  %s   |   population %d   |   map %dx%d, %d buildings%s   |   budget $%.2f / $%.0f this month  (%s)%s" % [
		clock.get("weekday", ""), day, clock.get("hhmm", ""), alive, w, h, nb, growth, spent, float(budget.get("budget", 75)), str(budget.get("model", "")),
		"   |   the town is dreaming through an outage (catching up)" if catching_up else ""]
	var lines := PackedStringArray()
	for e in events.slice(maxi(0, events.size() - 6)):
		lines.append("• " + str(e.text))
	events_label.text = "\n".join(lines)
	if connected:
		status_label.text = "tick %d   conversations %d   births %d   deaths %d   arrivals %d   departures %d   consciousness calls %d" % [
			int(clock.get("tick", 0)), int(stats.get("conversations", 0)), int(stats.get("births", 0)), int(stats.get("deaths", 0)), int(stats.get("arrivals", 0)), int(stats.get("departures", 0)), int(stats.get("tier2_calls", 0))]

func _show_citizen(c: Dictionary) -> void:
	panel.visible = true
	panel_title.text = "%s, %d (%s) — %s" % [c.name, int(c.age), c.pronouns, c.occupation]
	var t := "[b]Mood:[/b] %s    [b]Now:[/b] %s\n[b]Thought:[/b] [i]%s[/i]\n\n" % [c.mood, c.action, c.thought]
	t += "[b]Innate:[/b] %s\n[b]Learned:[/b] %s\n[b]Lifestyle:[/b] %s\n[b]Currently:[/b] %s\n[b]Home:[/b] %s   [b]Work:[/b] %s   [b]Arrived:[/b] %s\n\n" % [c.innate, c.learned, c.lifestyle, c.currently, c.home, c.work, c.arrived]
	t += "[b]Plan for today[/b] %s\n" % ("(their own)" if c.plan_is_tier2 else "(habit)")
	for b in c.plan:
		t += "  %s  %s — %s\n" % [b.at, b.place, b.action]
	t += "\n[b]Relationships[/b]\n"
	for r in c.relationships:
		t += "  %s — %s (%.2f) %s\n" % [r.name, r.kind, float(r.score), r.note]
	if c.conv.size() > 0:
		t += "\n[b]Talking now[/b]\n"
		for l in c.conv:
			t += "  %s\n" % l
	t += "\n[b]Recent memories[/b]\n"
	var mems: Array = c.memories
	mems.reverse()
	for m in mems:
		t += "  [color=#aaaaaa]%s[/color] [%s %d] %s\n" % [m.when, m.kind, int(m.imp), m.text]
	t += "\n[b]Conversation log[/b]\n"
	var chats: Array = c.conversations
	chats.reverse()
	for ch in chats:
		t += "  [color=#aaaaaa]%s[/color] %s\n" % [ch.when, ch.text]
	panel_text.text = t

func _update_news() -> void:
	news_list.clear()
	for issue in journal.get("issues", []):
		news_list.add_item(str(issue.title))
	var name := str(journal.get("name", ""))
	if journal.get("issues", []).size() > 0:
		_show_issue(0)
	else:
		news_text.text = "[i]%s[/i]\n\nNo issue has been printed yet. The Chronicler names the paper on its first run." % (name if name != "" else "The newspaper has no name yet.")

func _show_issue(i: int) -> void:
	var issues: Array = journal.get("issues", [])
	if i < 0 or i >= issues.size():
		return
	var text := str(issues[i].text)
	# tiny markdown: headings and bold
	var out := PackedStringArray()
	for line in text.split("\n"):
		if line.begins_with("# "):
			out.append("[font_size=18][b]%s[/b][/font_size]" % line.substr(2))
		elif line.begins_with("## "):
			out.append("[font_size=14][b]%s[/b][/font_size]" % line.substr(3))
		else:
			out.append(line.replace("**", "[b]").replace("[b]", "[b]", ))
	news_text.text = "\n".join(out)

# ---------------------------------------------------------------- input
func _unhandled_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		if ev.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam.zoom = (cam.zoom * 1.1).clamp(Vector2(0.4, 0.4), Vector2(5, 5))
		elif ev.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam.zoom = (cam.zoom / 1.1).clamp(Vector2(0.4, 0.4), Vector2(5, 5))
		elif ev.button_index == MOUSE_BUTTON_LEFT:
			dragging = ev.pressed
			if ev.pressed:
				_click(world.get_global_mouse_position())
		elif ev.button_index == MOUSE_BUTTON_MIDDLE or ev.button_index == MOUSE_BUTTON_RIGHT:
			dragging = ev.pressed
	elif ev is InputEventMouseMotion and dragging:
		cam.position -= ev.relative / cam.zoom

func _click(pos: Vector2) -> void:
	var best := -1
	var bd := 14.0
	for id in sprites:
		if not sprites[id].visible:
			continue
		var d: float = sprites[id].position.distance_to(pos)
		if d < bd:
			bd = d
			best = id
	if best >= 0:
		selected = best
		last_detail_request = 0.0
		dragging = false
