# The viewer. Connects to the world server over WebSocket, renders what it is told, simulates nothing.
# Drawing lives in map_renderer.gd (ground + buildings), citizen_sprite.gd (people) and hud.gd; art_loader.gd
# turns viewer/art/manifest.json into textures. Every part keeps a procedural fallback for missing art.
extends Node

const TILE := 16
const ArtLoader = preload("res://viewer/art_loader.gd")
const MapRenderer = preload("res://viewer/map_renderer.gd")
const CitizenSprite = preload("res://viewer/citizen_sprite.gd")
const Hud = preload("res://viewer/hud.gd")

var ws := WebSocketPeer.new()
var url := ""
var connected := false
var reconnect_at := 0.0
var map := {}
var citizens := {}        # id -> data
var sprites := {}         # id -> citizen_sprite
var clock := {}
var budget := {}
var stats := {}
var history := []
var events := []
var selected := -1
var last_detail_request := 0.0
var population := 0
var catching_up := false
var font: Font
var art = null
var world_info := {}       # season, weather, light, tint — from the server
var modulate_node: CanvasModulate
var light_node: Node2D     # window lights, on a viewport-following layer above the night modulate
var world: Node2D
var cam: Camera2D
var map_node: Node2D
var citizen_layer: Node2D
var hud: CanvasLayer
var dragging := false
var visitor_id := -1      # the citizen we walk as, once joined
var shot_path := ""      # --screenshot=<png>: save the view a few seconds after connecting, then quit (dev aid)
var shot_at := 0.0

func _ready() -> void:
	font = ThemeDB.fallback_font
	art = ArtLoader.new()
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
		var q := str(JavaScriptBridge.eval("new URLSearchParams(location.search).get('ws') || ''"))
		if q.begins_with("ws://") or q.begins_with("wss://"):
			return q   # dev aid: index.html?ws=ws://127.0.0.1:9002
		var host := str(JavaScriptBridge.eval("location.host"))
		var proto := str(JavaScriptBridge.eval("location.protocol"))
		return ("wss://" if proto == "https:" else "ws://") + host + "/ws"
	return "ws://127.0.0.1:9001"

func _connect() -> void:
	ws = WebSocketPeer.new()
	ws.inbound_buffer_size = 1 << 22
	ws.connect_to_url(url)
	connected = false
	hud.set_status("connecting to %s" % url)

func _build_scene() -> void:
	world = Node2D.new()
	add_child(world)
	modulate_node = CanvasModulate.new()
	world.add_child(modulate_node)
	map_node = MapRenderer.new()
	map_node.art = art
	map_node.font = font
	world.add_child(map_node)
	citizen_layer = Node2D.new()
	citizen_layer.y_sort_enabled = true
	world.add_child(citizen_layer)
	cam = Camera2D.new()
	cam.zoom = Vector2(1.6, 1.6)
	cam.position = Vector2(24 * TILE, 18 * TILE)
	world.add_child(cam)
	cam.make_current()
	var lights := CanvasLayer.new()
	lights.layer = 1
	lights.follow_viewport_enabled = true
	add_child(lights)
	light_node = Node2D.new()
	lights.add_child(light_node)
	map_node.light_node = light_node
	light_node.draw.connect(map_node._draw_lights)
	hud = Hud.new()
	hud.layer = 2
	add_child(hud)
	hud.build(func(): selected = -1, _send)

func _send(msg: Dictionary) -> void:
	if ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		ws.send_text(JSON.stringify(msg))

# ---------------------------------------------------------------- network
func _process(_delta: float) -> void:
	ws.poll()
	var st := ws.get_ready_state()
	if st == WebSocketPeer.STATE_OPEN:
		if not connected:
			connected = true
			ws.send_text(JSON.stringify({"type": "hello"}))
			hud.set_status("connected")
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
		print("viewer: fps %.0f" % Engine.get_frames_per_second())
		get_tree().quit()
	elif st == WebSocketPeer.STATE_CLOSED:
		if connected or reconnect_at == 0.0:
			connected = false
			reconnect_at = Time.get_unix_time_from_system() + 3.0
			hud.set_status("disconnected — retrying")
		elif Time.get_unix_time_from_system() > reconnect_at:
			reconnect_at = Time.get_unix_time_from_system() + 3.0
			_connect()

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
			world_info = m.get("world", world_info)
			map_node.set_map(map)
			_rebuild_sprites()
			_apply_world()
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
					if sprites.has(id):
						sprites[id].apply(c)
				else:
					need_roster = true
			for e in m.get("events", []):
				events.append(e)
			while events.size() > 40:
				events.remove_at(0)
			if need_roster or m.get("roster_changed", false):
				ws.send_text(JSON.stringify({"type": "hello"}))
			world_info = m.get("world", world_info)
			_apply_world()
			_update_hud()
		"map":
			map = m.map
			map_node.set_map(map)
		"citizen":
			hud.show_citizen(m.citizen)
		"journal":
			hud.update_news(m)
		"visitor":
			if m.get("ok", false) and m.has("id"):
				visitor_id = int(m.id)
				hud.visitor_joined(str(m.get("name", "")))
			hud.visitor_reply(m)

func _rebuild_sprites() -> void:
	for id in sprites:
		sprites[id].queue_free()
	sprites.clear()
	for id in citizens:
		var c: Dictionary = citizens[id]
		var s := CitizenSprite.new()
		citizen_layer.add_child(s)
		s.setup(c, art.frames_for(str(c.get("name", ""))), font)
		sprites[id] = s

## light by the clock (and the weather), ground by the season, people inside closed buildings out of sight
func _apply_world() -> void:
	var light := clampf(float(world_info.get("light", 1.0)), 0.0, 1.0)
	var night := Color(0.42, 0.48, 0.78)   # deep, never muddy
	modulate_node.color = Color(str(world_info.get("tint", "#ffffff"))) * night.lerp(Color.WHITE, light)
	map_node.set_world(world_info, citizens)
	var closed := {}
	for b in map.get("buildings", []):
		if not b.get("open", false):
			closed[int(b.id)] = true
	for id in sprites:
		var c: Dictionary = citizens.get(id, {})
		sprites[id].set_inside(closed.has(int(c.get("place", 0))) and str(c.get("activity", "")) != "walking")

func _update_hud() -> void:
	var alive := 0
	for id in citizens:
		if citizens[id].get("alive", true):
			alive += 1
	hud.update(clock, budget, stats, events, history, map, alive, catching_up, connected, world_info)

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
	elif visitor_id >= 0:   # visiting: a click on the ground is where we walk
		_send({"type": "move", "x": int(floor(pos.x / TILE)), "y": int(floor(pos.y / TILE))})
		dragging = false
